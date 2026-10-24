"""NTRIP client for CORS position cross-checking.

Pure Python 3 implementation using only the standard library.
Fetches sourcetables, picks mountpoints, generates GGA sentences,
and captures RTCM streams to files.
"""

import base64
import math
import os
import socket
import ssl
import time
from datetime import datetime
from threading import Event
from typing import Callable, Dict, List, Optional, Tuple


class NtripError(Exception):
    """NTRIP client error with a machine-readable kind."""

    def __init__(self, kind: str, message: str):
        super().__init__(message)
        self.kind = kind


def _open(host: str, port: int, tls: bool, timeout: float) -> socket.socket:
    """Open a TCP connection, optionally wrapped in TLS."""
    try:
        sock = socket.create_connection((host, port), timeout=timeout)
    except (socket.timeout, TimeoutError) as e:
        raise NtripError("timeout", "connection timed out") from e
    except OSError as e:
        raise NtripError("connect", "failed to connect") from e

    if tls:
        try:
            ctx = ssl.create_default_context()
            sock = ctx.wrap_socket(sock, server_hostname=host)
        except (socket.timeout, TimeoutError) as e:
            sock.close()
            raise NtripError("timeout", "TLS handshake timed out") from e
        except ssl.SSLError as e:
            sock.close()
            raise NtripError("tls", "TLS handshake failed") from e
        except OSError as e:
            sock.close()
            raise NtripError("connect", "TLS connection failed") from e

    return sock


def _request(path: str, host: str, port: int,
             username: str, password: str) -> bytes:
    """Build an NTRIP HTTP request."""
    auth = base64.b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")
    req = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        f"Ntrip-Version: Ntrip/2.0\r\n"
        f"User-Agent: NTRIP GeoMaxima/1.0\r\n"
        f"Authorization: Basic {auth}\r\n"
        f"Connection: close\r\n"
        f"\r\n"
    )
    return req.encode("utf-8")


def _read_headers(sock: socket.socket, timeout: float) -> Tuple[str, Dict[str, str], bytes]:
    """Read HTTP response headers until the blank line."""
    sock.settimeout(timeout)
    data = b""
    try:
        while b"\r\n\r\n" not in data:
            chunk = sock.recv(4096)
            if not chunk:
                raise NtripError("protocol", "empty response from server")
            data += chunk
            if len(data) > 16384:
                raise NtripError("protocol", "response headers too large")
    except (socket.timeout, TimeoutError) as e:
        raise NtripError("timeout", "timed out reading headers") from e

    header_end = data.find(b"\r\n\r\n")
    header_text = data[:header_end].decode("utf-8", errors="replace")
    leftover = data[header_end + 4:]

    lines = header_text.split("\r\n")
    status_line = lines[0]
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            name, value = line.split(":", 1)
            headers[name.strip().lower()] = value.strip()

    # Validate status
    if status_line.startswith("ICY 200") or status_line.startswith("HTTP/1.") and " 200 " in status_line:
        pass
    elif status_line.startswith("SOURCETABLE 200"):
        pass
    elif " 401 " in status_line or " 403 " in status_line:
        raise NtripError("auth", "authentication failed")
    elif " 404 " in status_line:
        raise NtripError("not_found", "mountpoint not found")
    else:
        raise NtripError("protocol", "unexpected server response")

    return status_line, headers, leftover


class _ChunkedDecoder:
    """Incremental HTTP chunked transfer decoder."""

    def __init__(self):
        self._buffer = b""
        self._done = False

    def feed(self, data: bytes) -> bytes:
        """Feed raw data, return decoded output."""
        self._buffer += data
        output = b""

        while not self._done:
            # Find chunk size line
            crlf = self._buffer.find(b"\r\n")
            if crlf == -1:
                break

            size_line = self._buffer[:crlf].decode("ascii", errors="replace").strip()
            try:
                chunk_size = int(size_line, 16)
            except ValueError:
                self._done = True
                break

            # Check if complete chunk is available
            needed = crlf + 2 + chunk_size + 2  # size line + CRLF + data + CRLF
            if len(self._buffer) < needed:
                break

            # Consume and decode
            self._buffer = self._buffer[crlf + 2:]  # Remove size line + CRLF
            output += self._buffer[:chunk_size]
            self._buffer = self._buffer[chunk_size + 2:]  # Remove data + CRLF

            if chunk_size == 0:
                self._done = True
                break

        return output


def _write_all(fd: int, data: bytes) -> None:
    """Write all bytes to fd, handling partial writes."""
    remaining = data
    while remaining:
        written = os.write(fd, remaining)
        remaining = remaining[written:]


def fetch_sourcetable(host: str, port: int, username: str, password: str,
                      tls: bool = False, timeout: float = 15.0) -> List[Dict]:
    """Fetch and parse the NTRIP sourcetable."""
    sock = _open(host, port, tls, timeout)
    try:
        sock.sendall(_request("/", host, port, username, password))
        status, headers, leftover = _read_headers(sock, timeout)

        # Accept either NTRIP 1.x "SOURCETABLE 200" or NTRIP 2.x HTTP 200 with sourcetable content-type
        is_sourcetable = (status.startswith("SOURCETABLE 200") or
                          "sourcetable" in headers.get("content-type", "").lower())
        if not is_sourcetable:
            raise NtripError("protocol", "unexpected server response")

        # Read body
        body = leftover
        sock.settimeout(timeout)
        try:
            while b"ENDSOURCETABLE" not in body:
                try:
                    chunk = sock.recv(4096)
                except (socket.timeout, TimeoutError) as e:
                    if b"STR;" in body:
                        break
                    raise NtripError("timeout", "timed out reading sourcetable") from e
                except OSError as e:
                    if b"STR;" in body:
                        break
                    raise NtripError("connect", "connection lost") from e
                if not chunk:
                    break
                body += chunk
                if len(body) > 524288:  # 512 KiB limit
                    break
        except NtripError:
            raise

        # Handle chunked encoding
        if "chunked" in headers.get("transfer-encoding", ""):
            decoder = _ChunkedDecoder()
            body = decoder.feed(body)

        # Parse STR lines
        entries = []
        for line in body.decode("utf-8", errors="replace").split("\n"):
            if not line.startswith("STR;"):
                continue
            fields = line.split(";")
            if len(fields) < 12:
                continue
            try:
                entry = {
                    "mountpoint": fields[1],
                    "identifier": fields[2],
                    "format": fields[3],
                    "nav_system": fields[6],
                    "network": fields[7],
                    "lat": float(fields[9]) if fields[9] else None,
                    "lon": float(fields[10]) if fields[10] else None,
                    "nmea": fields[11] == "1",
                }
                entries.append(entry)
            except (ValueError, IndexError):
                continue

        return entries
    finally:
        sock.close()


def _haversine(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Great-circle distance in km."""
    R = 6371.0
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = (math.sin(dlat / 2) ** 2 +
         math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) *
         math.sin(dlon / 2) ** 2)
    return R * 2 * math.asin(math.sqrt(a))


def pick_mountpoint(entries: List[Dict], lat: float, lon: float,
                    need_nmea: bool = True) -> Optional[Dict]:
    """Pick the closest RTCM 3 mountpoint."""
    candidates = []
    for entry in entries:
        fmt = entry["format"].upper()
        if "RTCM 3" not in fmt and "RTCM3" not in fmt:
            continue
        if entry["lat"] is None or entry["lon"] is None:
            continue
        if need_nmea and not entry["nmea"]:
            continue
        dist = _haversine(lat, lon, entry["lat"], entry["lon"])
        candidates.append((dist, entry))

    if not candidates:
        return None

    candidates.sort(key=lambda x: x[0])
    return candidates[0][1]


def make_gga(lat: float, lon: float, height: float,
             utc_time: Optional[datetime] = None) -> str:
    """Generate a NMEA GGA sentence."""
    if utc_time is None:
        utc_time = datetime.utcnow()

    time_str = utc_time.strftime("%H%M%S.%f")[:9]

    lat_deg = abs(lat)
    lat_d = int(lat_deg)
    lat_m = (lat_deg - lat_d) * 60
    lat_ns = "N" if lat >= 0 else "S"

    lon_deg = abs(lon)
    lon_d = int(lon_deg)
    lon_m = (lon_deg - lon_d) * 60
    lon_ew = "E" if lon >= 0 else "W"

    # Guard against minutes rounding to 60
    lat_m_str = f"{lat_m:010.7f}"
    if lat_m_str.startswith("60"):
        lat_d += 1
        lat_m_str = "0000000.000"

    lon_m_str = f"{lon_m:010.7f}"
    if lon_m_str.startswith("60"):
        lon_d += 1
        lon_m_str = "0000000.000"

    sentence = (
        f"$GPGGA,{time_str},"
        f"{lat_d:02d}{lat_m_str},{lat_ns},"
        f"{lon_d:03d}{lon_m_str},{lon_ew},"
        f"1,10,1.0,{height:.3f},M,0.0,M,,"
    )

    # Calculate checksum
    checksum = 0
    for ch in sentence[1:]:  # Skip '$'
        checksum ^= ord(ch)

    return f"{sentence}*{checksum:02X}\r\n"


def capture_stream(host: str, port: int, mountpoint: str,
                   username: str, password: str, out_path: str,
                   duration_s: float, tls: bool = False,
                   gga_provider: Optional[Callable[[], str]] = None,
                   gga_interval_s: float = 10.0,
                   connect_timeout: float = 15.0,
                   idle_timeout: float = 30.0,
                   stop_event: Optional[Event] = None) -> Dict:
    """Capture an NTRIP stream to a file."""
    sock = _open(host, port, tls, connect_timeout)
    fd = None
    try:
        sock.sendall(_request(f"/{mountpoint}", host, port, username, password))
        status, headers, leftover = _read_headers(sock, connect_timeout)

        # Check for sourcetable response (mountpoint not found)
        is_sourcetable = (status.startswith("SOURCETABLE 200") or
                          "sourcetable" in headers.get("content-type", "").lower())
        if is_sourcetable:
            raise NtripError("not_found", "mountpoint not found")

        # Open output file
        fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)

        # Send initial GGA if provider given
        if gga_provider is not None:
            sock.sendall(gga_provider().encode("ascii"))

        # Stream capture loop
        sock.settimeout(0.25)
        decoder = None
        if "chunked" in headers.get("transfer-encoding", ""):
            decoder = _ChunkedDecoder()

        total_bytes = 0
        start_time = time.monotonic()
        first_data_time = None
        last_data_time = time.monotonic()
        next_gga_time = start_time + gga_interval_s

        # Write leftover from headers
        if leftover:
            if decoder:
                decoded = decoder.feed(leftover)
            else:
                decoded = leftover
            if decoded:
                _write_all(fd, decoded)
                total_bytes += len(decoded)
                first_data_time = time.monotonic() - start_time
                last_data_time = time.monotonic()

        while True:
            elapsed = time.monotonic() - start_time
            if elapsed >= duration_s:
                break
            if stop_event is not None and stop_event.is_set():
                break

            # Send periodic GGA
            now = time.monotonic()
            if gga_provider is not None and now >= next_gga_time:
                try:
                    sock.sendall(gga_provider().encode("ascii"))
                except OSError:
                    pass
                next_gga_time = now + gga_interval_s

            try:
                chunk = sock.recv(4096)
            except (socket.timeout, TimeoutError):
                # No data yet; check idle timeout and continue
                if time.monotonic() - last_data_time > idle_timeout:
                    raise NtripError("no_data", "no data received from the stream")
                continue
            except OSError:
                break

            if not chunk:
                # Server closed connection
                if total_bytes == 0:
                    raise NtripError("no_data", "no data received from the stream")
                break

            if decoder:
                chunk = decoder.feed(chunk)
            if chunk:
                _write_all(fd, chunk)
                total_bytes += len(chunk)
                if first_data_time is None:
                    first_data_time = time.monotonic() - start_time
                last_data_time = time.monotonic()

            # Check idle timeout
            if time.monotonic() - last_data_time > idle_timeout:
                raise NtripError("no_data", "no data received from the stream")

        elapsed = time.monotonic() - start_time
        return {
            "bytes": total_bytes,
            "seconds": elapsed,
            "first_data_s": first_data_time,
            "mountpoint": mountpoint,
        }
    finally:
        if fd is not None:
            os.close(fd)
        sock.close()
