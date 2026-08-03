#!/usr/bin/env python3
"""
GeoMaxima LCD Display Service
==============================

Drives a small SPI-connected TFT display (e.g. a 3.5" ILI9486/MPI3501
touchscreen) showing rotating info slides about this base station:
station identity/network addresses, GNSS fix status, system health,
and a satellite count summary.

Runs as its own standalone systemd service, entirely separate from the
main rtkbase_web Flask process. It reads GNSS/fix data by connecting
to the ALREADY-RUNNING Flask/SocketIO server as a client (the same way
a browser viewing the Status page does), rather than duplicating or
competing with the single rtkrcv process that server already owns.

Hardware: SPI must be enabled (raspi-config nonint do_spi 0, done
automatically during install.sh Stage 1/5 - requires a reboot to take
effect on first setup).

GPIO pin assignment (DC=24, RST=25, hardware SPI0/CE0) matches the
common default pinout for MPI3501-family 3.5" displays. If your
specific board uses different pins, adjust LCD_DC_PIN/LCD_RST_PIN
below - this has NOT been hardware-verified and may need adjustment
based on the actual physical wiring.
"""

import os
import sys
import time
import socket as pysocket
import threading
import configparser
import logging
from datetime import timedelta

import psutil
import socketio
from PIL import ImageFont

from luma.core.interface.serial import spi
from luma.lcd.device import ili9486
import luma.lcd.const
from time import sleep as _sleep
from luma.core.render import canvas
from luma.core.framebuffer import full_frame


class ili9486_clone(ili9486):
    """
    Alternate ILI9486 init sequence for cheap clone boards (e.g. MPI3501)
    that don't use the Waveshare-specific 16-bit-padded command format
    the standard luma.lcd ili9486 class was built for. Many clone boards
    render only a quarter of the screen or show interlacing artifacts
    with the stock init sequence.

    Based on a community-reported fix at:
    https://github.com/rm-hull/luma.lcd/issues/135
    """

    def __init__(self, serial_interface=None, width=320, height=480, rotate=0,
                 framebuffer=None, h_offset=0, v_offset=0, bgr=False, invert=True,
                 **kwargs):
        # Deliberately skip ili9486.__init__ (which runs the incompatible
        # padded init sequence) and go straight to its parent instead.
        super(ili9486, self).__init__(luma.lcd.const.ili9486, serial_interface, **kwargs)
        self.capabilities(width, height, rotate, mode="RGB")
        self.init_framebuffer(framebuffer, 25)

        if h_offset != 0 or v_offset != 0:
            def offset(bbox):
                left, top, right, bottom = bbox
                return (left + h_offset, top + v_offset, right + h_offset, bottom + v_offset)
            self.apply_offsets = offset
        else:
            self.apply_offsets = lambda bbox: bbox

        order = 0x00 if bgr else 0x08

        self.command(0x11)  # sleep out
        _sleep(0.150)
        self.command(0x3a, 0x66)  # Interface Pixel Format
        self.command(0x36, 0x88 | order)  # Memory Access control (MADCTL)
        self.command(0xc2, 0x44)  # Power Control 3
        self.command(0xc5, 0x00, 0x00, 0x00, 0x00)  # VCOM control
        self.command(0xe0,
            0x0f, 0x1f, 0x1c, 0x0c, 0x0f, 0x08, 0x48, 0x98,
            0x37, 0x0a, 0x13, 0x04, 0x11, 0x0d, 0x00)  # Positive Gamma control
        self.command(0x11)
        _sleep(0.150)
        self.clear()
        self.show()

    def display(self, image):
        """
        Renders a 24-bit RGB image, matching the parent class's method
        but WITHOUT the Waveshare-specific 16-bit zero-padding on the
        column/row address window commands (0x2a/0x2b) - this clone
        board's controller does not expect that padding on per-frame
        pixel writes, only the init sequence needed adjusting.
        """
        assert image.mode == self.mode
        assert image.size == self.size

        image = self.preprocess(image)

        for image, bounding_box in self.framebuffer.redraw(image):
            top, left, bottom, right = self.apply_offsets(bounding_box)

            self.command(0x2a, top >> 8, top & 0xff, (bottom - 1) >> 8, (bottom - 1) & 0xff)     # Set row addr (no padding)
            self.command(0x2b, left >> 8, left & 0xff, (right - 1) >> 8, (right - 1) & 0xff)     # Set column addr (no padding)
            self.command(0x2c)                                                                    # Memory write

            self.data(image.tobytes())

# --- Make web_app/ importable so we can reuse existing config/network code ---
_REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
_WEB_APP_DIR = os.path.join(_REPO_ROOT, "web_app")
if _WEB_APP_DIR not in sys.path:
    sys.path.insert(0, _WEB_APP_DIR)

from network_infos import get_interfaces_infos  # noqa: E402
from wireguard_settings import get_wireguard_settings  # noqa: E402

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("lcd_display")

# --- Hardware configuration ---
LCD_DC_PIN = 24
LCD_RST_PIN = 25
# luma.lcd's ili9486 class only supports native portrait mode
# (width=320, height=480) - landscape orientation is achieved via the
# rotate parameter (1 or 3), not by passing swapped width/height
# values directly. Try rotate=1 first; switch to rotate=3 if the image
# appears upside-down on the actual hardware.
LCD_WIDTH = 320
LCD_HEIGHT = 480
LCD_ROTATE = 1

SLIDE_SECONDS = 5
SOCKETIO_RECONNECT_DELAY = 5


def _get_web_port():
    """Read [general] web_port from settings.conf, falling back to settings.conf.default, then 80."""
    config = configparser.ConfigParser()
    default_path = os.path.join(_REPO_ROOT, "settings.conf.default")
    live_path = os.path.join(_REPO_ROOT, "settings.conf")
    read_files = [p for p in (default_path, live_path) if os.path.exists(p)]
    if read_files:
        config.read(read_files)
    if config.has_section("general") and config.has_option("general", "web_port"):
        return config.get("general", "web_port")
    return "80"


class StationData:
    """Thread-safe holder for the latest known values from all data sources."""

    def __init__(self):
        self._lock = threading.Lock()
        self.solution_status = "unknown"
        self.lat = None
        self.lon = None
        self.height = None
        self.sat_counts = {}  # e.g. {"G": 8, "R": 6, "E": 5, "C": 7}
        self.sat_total = 0

    def update_coordinate(self, msg):
        logger.info("DEBUG coordinate broadcast raw payload: %r", msg)
        with self._lock:
            self.solution_status = msg.get("solution status", self.solution_status)
            pos_key = "pos llh single (deg,m) rover"
            pos_value = msg.get(pos_key)
            if pos_value:
                parts = pos_value.split(",")
                if len(parts) >= 3:
                    try:
                        self.lat = float(parts[0])
                        self.lon = float(parts[1])
                        self.height = float(parts[2])
                    except ValueError:
                        pass

    def update_satellites(self, obs_rover):
        if not isinstance(obs_rover, dict):
            return
        counts = {}
        for key in obs_rover.keys():
            if key == "gps_time":
                continue
            prefix = key[0].upper() if key else "?"
            counts[prefix] = counts.get(prefix, 0) + 1
        with self._lock:
            self.sat_counts = counts
            self.sat_total = sum(counts.values())

    def snapshot(self):
        with self._lock:
            return {
                "solution_status": self.solution_status,
                "lat": self.lat,
                "lon": self.lon,
                "height": self.height,
                "sat_counts": dict(self.sat_counts),
                "sat_total": self.sat_total,
            }


station_data = StationData()


def _start_socketio_client():
    """Runs forever in a background thread, connecting/reconnecting to the
    local Flask/SocketIO server's "/test" namespace and updating
    station_data as broadcasts arrive."""
    port = _get_web_port()
    url = "http://127.0.0.1:%s" % port

    sio = socketio.Client(reconnection=True, reconnection_delay=SOCKETIO_RECONNECT_DELAY)

    @sio.on("connect", namespace="/test")
    def on_connect():
        logger.info("Connected to local Flask/SocketIO server at %s", url)

    @sio.on("disconnect", namespace="/test")
    def on_disconnect():
        logger.warning("Disconnected from local Flask/SocketIO server")

    @sio.on("coordinate broadcast", namespace="/test")
    def on_coordinate(msg):
        try:
            station_data.update_coordinate(msg)
        except Exception as e:
            logger.error("Failed to process coordinate broadcast: %s", e)

    @sio.on("satellite broadcast rover", namespace="/test")
    def on_satellites(msg):
        try:
            station_data.update_satellites(msg)
        except Exception as e:
            logger.error("Failed to process satellite broadcast: %s", e)

    while True:
        try:
            sio.connect(url, namespaces=["/test"])
            sio.wait()
        except Exception as e:
            logger.warning("SocketIO connection failed (%s), retrying in %ss", e, SOCKETIO_RECONNECT_DELAY)
            time.sleep(SOCKETIO_RECONNECT_DELAY)


def _get_router_ip():
    try:
        for iface in get_interfaces_infos():
            device = (iface.get("device") or "")
            if device.startswith("eth") or device.startswith("en"):
                ipv4 = iface.get("ipv4")
                if ipv4:
                    return ipv4[0]
    except Exception as e:
        logger.error("Failed to read router IP: %s", e)
    return "N/A"


def _get_wireguard_ip():
    try:
        settings = get_wireguard_settings()
        for item in settings:
            if isinstance(item, dict) and "address" in item:
                addr = item["address"]
                return addr.split("/")[0] if addr else "N/A"
    except Exception as e:
        logger.error("Failed to read WireGuard IP: %s", e)
    return "N/A"


def _get_cpu_temp_c():
    try:
        temps = psutil.sensors_temperatures()
        for key in ("cpu_thermal", "cpu-thermal", "coretemp"):
            if key in temps and temps[key]:
                return temps[key][0].current
        for entries in temps.values():
            if entries:
                return entries[0].current
    except Exception as e:
        logger.error("Failed to read CPU temp: %s", e)
    return None


def _get_disk_usage_percent(path="/"):
    try:
        return psutil.disk_usage(path).percent
    except Exception as e:
        logger.error("Failed to read disk usage: %s", e)
        return None


def _get_uptime_str():
    try:
        seconds = time.time() - psutil.boot_time()
        return str(timedelta(seconds=int(seconds)))
    except Exception as e:
        logger.error("Failed to read uptime: %s", e)
        return "N/A"


# --- Slide rendering ---

FONT_LARGE = ImageFont.load_default()
FONT_SMALL = ImageFont.load_default()
try:
    FONT_LARGE = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 26)
    FONT_SMALL = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 18)
except Exception:
    logger.warning("DejaVu fonts not found, falling back to default PIL font (will look small)")


def draw_slide_identity(draw, data):
    hostname = pysocket.gethostname()
    draw.text((10, 10), "GeoMaxima", font=FONT_LARGE, fill="white")
    draw.text((10, 50), "Host: %s" % hostname, font=FONT_SMALL, fill="white")
    draw.text((10, 80), "LAN IP: %s" % _get_router_ip(), font=FONT_SMALL, fill="white")
    draw.text((10, 110), "VPN IP: %s" % _get_wireguard_ip(), font=FONT_SMALL, fill="white")


def draw_slide_gnss(draw, data):
    status = data["solution_status"] or "unknown"
    color = {"fix": "lime", "float": "yellow", "single": "orange"}.get(status.lower(), "white")
    draw.text((10, 10), "GNSS Status", font=FONT_LARGE, fill="white")
    draw.text((10, 50), "Solution: %s" % status.upper(), font=FONT_SMALL, fill=color)
    if data["lat"] is not None:
        draw.text((10, 80), "Lat: %.8f" % data["lat"], font=FONT_SMALL, fill="white")
        draw.text((10, 105), "Lon: %.8f" % data["lon"], font=FONT_SMALL, fill="white")
        draw.text((10, 130), "Height: %.3f m" % data["height"], font=FONT_SMALL, fill="white")
    else:
        draw.text((10, 80), "No position data yet", font=FONT_SMALL, fill="gray")


def draw_slide_health(draw, data):
    draw.text((10, 10), "System Health", font=FONT_LARGE, fill="white")
    temp = _get_cpu_temp_c()
    temp_str = ("%.1f C" % temp) if temp is not None else "N/A"
    temp_color = "lime"
    if temp is not None:
        if temp >= 80:
            temp_color = "red"
        elif temp >= 70:
            temp_color = "yellow"
    draw.text((10, 50), "CPU Temp: %s" % temp_str, font=FONT_SMALL, fill=temp_color)

    disk = _get_disk_usage_percent("/")
    disk_str = ("%.0f%%" % disk) if disk is not None else "N/A"
    disk_color = "lime" if (disk is None or disk < 80) else ("yellow" if disk < 90 else "red")
    draw.text((10, 80), "Disk Used: %s" % disk_str, font=FONT_SMALL, fill=disk_color)

    draw.text((10, 110), "Uptime: %s" % _get_uptime_str(), font=FONT_SMALL, fill="white")


def draw_slide_satellites(draw, data):
    draw.text((10, 10), "Satellites", font=FONT_LARGE, fill="white")
    draw.text((10, 50), "Total: %d" % data["sat_total"], font=FONT_SMALL, fill="white")
    labels = {"G": "GPS", "R": "GLONASS", "E": "Galileo", "C": "BeiDou"}
    y = 80
    for prefix, name in labels.items():
        count = data["sat_counts"].get(prefix, 0)
        draw.text((10, y), "%s: %d" % (name, count), font=FONT_SMALL, fill="white")
        y += 25


SLIDES = [draw_slide_identity, draw_slide_gnss, draw_slide_health, draw_slide_satellites]


def main():
    logger.info("Starting GeoMaxima LCD Display service")

    listener_thread = threading.Thread(target=_start_socketio_client, daemon=True)
    listener_thread.start()

    serial = spi(port=0, device=0, gpio_DC=LCD_DC_PIN, gpio_RST=LCD_RST_PIN, bus_speed_hz=8000000)
    device = ili9486_clone(serial, width=LCD_WIDTH, height=LCD_HEIGHT, rotate=LCD_ROTATE, framebuffer=full_frame())

    slide_index = 0
    while True:
        data = station_data.snapshot()
        try:
            with canvas(device) as draw:
                draw.rectangle(device.bounding_box, outline="black", fill="black")
                SLIDES[slide_index](draw, data)
        except Exception as e:
            logger.error("Failed to render slide %d: %s", slide_index, e)

        slide_index = (slide_index + 1) % len(SLIDES)
        time.sleep(SLIDE_SECONDS)


if __name__ == "__main__":
    main()
