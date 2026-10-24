"""Shared fake servers and tools for CORS RTK tests (standard library only)."""

import base64
import datetime
import os
import socket
import sys
import threading
import time
from importlib.machinery import ModuleSpec
from unittest import mock


# ---------------------------------------------------------------------------
# Stub installer for numpy/scipy/pyproj
# ---------------------------------------------------------------------------

_STUB_MODULES = {"numpy", "scipy", "pyproj"}
_stub_installed = False


class _StubFinder:
    def find_spec(self, fullname, path=None, target=None):
        if fullname in _STUB_MODULES:
            return ModuleSpec(fullname, self, is_package=True)
        return None

    def create_module(self, spec):
        m = mock.MagicMock()
        m.__path__ = []
        m.__name__ = spec.name
        m.__spec__ = spec
        return m

    def exec_module(self, module):
        pass


def install_stubs():
    """Install sys.meta_path finder that stubs numpy, scipy and pyproj. Idempotent."""
    global _stub_installed
    if _stub_installed:
        return
    sys.meta_path.insert(0, _StubFinder())
    _stub_installed = True


# ---------------------------------------------------------------------------
# NMEA helpers
# ---------------------------------------------------------------------------

def gga_checksum(body):
    """Compute NMEA checksum (XOR of all characters) as two uppercase hex digits."""
    xor = 0
    for ch in body:
        xor ^= ord(ch)
    return "%02X" % xor


def make_gga_sentence(lat, lon, alt, geoid_sep=0.0, quality=1, nsats=8):
    """Build a $GPGGA sentence with the given parameters.

    lat/lon in decimal degrees (sign determines N/S, E/W).
    alt in metres. geoid_sep in metres. quality 0-8. nsats integer.
    Time is set to UTC now.
    """
    now = datetime.datetime.utcnow()
    hhmmss = "%02d%02d%02d.00" % (now.hour, now.minute, now.second)

    # Convert decimal degrees to ddmm.mmmmmm
    lat_abs = abs(lat)
    lon_abs = abs(lon)
    lat_deg = int(lat_abs)
    lat_min = (lat_abs - lat_deg) * 60.0
    lon_deg = int(lon_abs)
    lon_min = (lon_abs - lon_deg) * 60.0

    ns = "N" if lat >= 0 else "S"
    ew = "E" if lon >= 0 else "W"

    body = (
        f"GPGGA,{hhmmss},{lat_deg:02d}{lat_min:09.6f},{ns},"
        f"{lon_deg:03d}{lon_min:09.6f},{ew},{quality},{nsats},1.0,"
        f"{alt:.1f},M,{geoid_sep:.1f},M,,"
    )
    return f"${body}*{gga_checksum(body)}\r\n"


# ---------------------------------------------------------------------------
# Fake NTRIP caster
# ---------------------------------------------------------------------------

class FakeCaster:
    """Minimal NTRIP v1 caster for testing. One thread per connection."""

    def __init__(self, user="u1", password="p1", mountpoints=("MP1",),
                 sourcetable_lines=None, stream_seconds=5.0):
        self.user = user
        self.password = password
        self.mountpoints = mountpoints
        self.stream_seconds = stream_seconds
        if sourcetable_lines is None:
            sourcetable_lines = [
                "STR;MP1;Sofia;RTCM 3.2;1004(1),1005(10);2;GPS+GLO;NET;BGR;42.70;26.40;1;0;sNTRIP;none;B;N;9600;",
                "STR;MP2;Far;RTCM 3.2;1004(1);2;GPS;NET;BGR;50.0;10.0;0;0;sNTRIP;none;B;N;9600;",
            ]
        self.sourcetable_lines = sourcetable_lines
        self.port = None
        self._server = None
        self._accept_thread = None
        self._stopping = False
        self._clients = []
        self._clients_lock = threading.Lock()
        self.after_headers = b""
        self.lock = threading.Lock()

    def start(self):
        self._server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._server.bind(("127.0.0.1", 0))
        self._server.listen(5)
        self.port = self._server.getsockname()[1]
        self._stopping = False
        self._accept_thread = threading.Thread(target=self._accept_loop, daemon=True)
        self._accept_thread.start()

    def stop(self):
        self._stopping = True
        with self._clients_lock:
            for c in self._clients:
                try:
                    c.close()
                except OSError:
                    pass
            self._clients.clear()
        if self._server:
            try:
                self._server.close()
            except OSError:
                pass
        if self._accept_thread:
            self._accept_thread.join(timeout=2.0)

    def _accept_loop(self):
        while not self._stopping:
            try:
                self._server.settimeout(0.5)
                conn, addr = self._server.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            t = threading.Thread(target=self._handle_client, args=(conn,), daemon=True)
            t.start()

    def _handle_client(self, conn):
        with self._clients_lock:
            self._clients.append(conn)
        try:
            conn.settimeout(5.0)
            data = b""
            while b"\r\n\r\n" not in data:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                data += chunk
            headers, _ = data.split(b"\r\n\r\n", 1)
            lines = headers.decode("utf-8", errors="replace").split("\r\n")
            request_line = lines[0]
            path = "/"
            if " " in request_line:
                parts = request_line.split(" ")
                if len(parts) >= 2:
                    path = parts[1]

            auth = None
            for line in lines[1:]:
                if line.lower().startswith("authorization:"):
                    auth = line.split(":", 1)[1].strip()

            if not self._check_auth(auth):
                conn.sendall(b"HTTP/1.1 401 Unauthorized\r\n\r\n")
                return

            if path == "/":
                self._send_sourcetable(conn)
            elif path.startswith("/") and path[1:] in self.mountpoints:
                self._send_stream(conn)
            else:
                self._send_sourcetable(conn)
        except OSError:
            pass
        finally:
            with self._clients_lock:
                if conn in self._clients:
                    self._clients.remove(conn)
            try:
                conn.close()
            except OSError:
                pass

    def _check_auth(self, auth):
        if not auth:
            return False
        try:
            if auth.startswith("Basic "):
                payload = auth[6:]
                decoded = base64.b64decode(payload).decode("utf-8")
                return decoded == f"{self.user}:{self.password}"
        except Exception:
            pass
        return False

    def _send_sourcetable(self, conn):
        body = ""
        for line in self.sourcetable_lines:
            body += line + "\r\n"
        body += "ENDSOURCETABLE\r\n"
        response = (
            "SOURCETABLE 200 OK\r\n"
            "Content-Type: text/plain\r\n"
            "\r\n"
        ) + body
        conn.sendall(response.encode("utf-8"))

    def _send_stream(self, conn):
        conn.sendall(b"ICY 200 OK\r\n\r\n")
        reader = threading.Thread(target=self._read_client, args=(conn,), daemon=True)
        reader.start()
        start = time.time()
        while not self._stopping:
            elapsed = time.time() - start
            if elapsed >= self.stream_seconds:
                break
            try:
                conn.sendall(b"RTCM-DATA")
            except OSError:
                break
            time.sleep(0.1)

    def _read_client(self, conn):
        try:
            while not self._stopping:
                conn.settimeout(0.5)
                try:
                    chunk = conn.recv(4096)
                except socket.timeout:
                    continue
                except OSError:
                    break
                if not chunk:
                    break
                with self.lock:
                    self.after_headers += chunk
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Fake receiver (two TCP servers)
# ---------------------------------------------------------------------------

class FakeReceiver:
    """Two tiny TCP servers: raw UBX and NMEA."""

    def __init__(self, silent_raw=False, silent_nmea=False):
        self.silent_raw = silent_raw
        self.silent_nmea = silent_nmea
        self.raw_port = None
        self.nmea_port = None
        self._raw_server = None
        self._nmea_server = None
        self._raw_thread = None
        self._nmea_thread = None
        self._stopping = False
        self._clients = []
        self._clients_lock = threading.Lock()

    def start(self):
        self._stopping = False
        self._raw_server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._raw_server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._raw_server.bind(("127.0.0.1", 0))
        self._raw_server.listen(5)
        self.raw_port = self._raw_server.getsockname()[1]
        self._raw_thread = threading.Thread(target=self._accept_loop, args=(self._raw_server, "raw"), daemon=True)
        self._raw_thread.start()

        self._nmea_server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._nmea_server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._nmea_server.bind(("127.0.0.1", 0))
        self._nmea_server.listen(5)
        self.nmea_port = self._nmea_server.getsockname()[1]
        self._nmea_thread = threading.Thread(target=self._accept_loop, args=(self._nmea_server, "nmea"), daemon=True)
        self._nmea_thread.start()

    def stop(self):
        self._stopping = True
        with self._clients_lock:
            for c in self._clients:
                try:
                    c.close()
                except OSError:
                    pass
            self._clients.clear()
        for srv in (self._raw_server, self._nmea_server):
            if srv:
                try:
                    srv.close()
                except OSError:
                    pass
        for t in (self._raw_thread, self._nmea_thread):
            if t:
                t.join(timeout=2.0)

    def _accept_loop(self, server, kind):
        while not self._stopping:
            try:
                server.settimeout(0.5)
                conn, addr = server.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            t = threading.Thread(target=self._handle_client, args=(conn, kind), daemon=True)
            t.start()

    def _handle_client(self, conn, kind):
        with self._clients_lock:
            self._clients.append(conn)
        try:
            if kind == "raw":
                if not self.silent_raw:
                    while not self._stopping:
                        try:
                            conn.sendall(b"UBXRAW")
                        except OSError:
                            break
                        time.sleep(0.1)
            elif kind == "nmea":
                if not self.silent_nmea:
                    conn.sendall(b"garbage\r\n")
                    conn.sendall(make_gga_sentence(42.6524, 26.4326, 170.5, 37.6, quality=0).encode("utf-8"))
                    while not self._stopping:
                        try:
                            conn.sendall(make_gga_sentence(42.6524, 26.4326, 170.5, 37.6).encode("utf-8"))
                        except OSError:
                            break
                        time.sleep(0.2)
        finally:
            with self._clients_lock:
                if conn in self._clients:
                    self._clients.remove(conn)
            try:
                conn.close()
            except OSError:
                pass


# ---------------------------------------------------------------------------
# Fake tools
# ---------------------------------------------------------------------------

def write_fake_tool(path, body):
    """Write a fake executable tool to path."""
    with open(path, "w") as f:
        f.write("#!/usr/bin/env python3\n")
        f.write(body)
    os.chmod(path, 0o755)


FAKE_CONVBIN_BODY = '''
import sys
import os
import time

def parse_args(args):
    outdir = None
    fmt = None
    input_file = None
    i = 0
    while i < len(args):
        if args[i] == "-d" and i + 1 < len(args):
            outdir = args[i + 1]
            i += 2
        elif args[i] == "-r" and i + 1 < len(args):
            fmt = args[i + 1]
            i += 2
        elif args[i] in ("-v", "-ti", "-tt", "-tr", "-ts", "-te", "-hm", "-ha", "-hr", "-hd") and i + 1 < len(args):
            i += 2
        else:
            input_file = args[i]
            i += 1
    return outdir, fmt, input_file

outdir, fmt, input_file = parse_args(sys.argv[1:])

mode = os.environ.get("FAKE_CONVBIN_MODE", "")
if mode == "fail":
    sys.exit(1)
if mode == "sleep":
    time.sleep(30)

if input_file:
    basename = os.path.basename(input_file)
    name, ext = os.path.splitext(basename)
    if not os.path.exists(outdir):
        os.makedirs(outdir)
    obs_path = os.path.join(outdir, name + ".obs")
    nav_path = os.path.join(outdir, name + ".nav")
    if mode != "nofile":
        if fmt == "rtcm3" and os.environ.get("FAKE_NO_BASE_POS") != "1":
            x, y, z = 4178200.1234, 2084711.5678, 4328800.9876
        else:
            x, y, z = 0.0, 0.0, 0.0
        approx_line = ("%14.4f%14.4f%14.4f" % (x, y, z)).ljust(60) + "APPROX POSITION XYZ\\n"
        end_line = " " * 60 + "END OF HEADER\\n"
        with open(obs_path, "w") as f:
            f.write(approx_line)
            f.write(end_line)
        with open(nav_path, "w") as f:
            f.write(end_line)
'''

FAKE_RNX2RTKP_BODY = '''
import sys
import os
import shutil

def parse_args(args):
    out = None
    conf = None
    i = 0
    while i < len(args):
        if args[i] == "-o" and i + 1 < len(args):
            out = args[i + 1]
            i += 2
        elif args[i] == "-k" and i + 1 < len(args):
            conf = args[i + 1]
            i += 2
        else:
            i += 1
    return out, conf

out, conf = parse_args(sys.argv[1:])

mode = os.environ.get("FAKE_RNX_MODE", "")
if mode == "fail":
    sys.exit(1)
if conf and not os.path.exists(conf):
    sys.exit(2)
if out and mode != "nofile":
    src = os.environ.get("FAKE_POS_SRC", "")
    if src and os.path.exists(src):
        shutil.copy(src, out)
'''


def make_tools(directory):
    """Write fake convbin and rnx2rtkp tools into directory. Returns (convbin_path, rnx2rtkp_path)."""
    convbin_path = os.path.join(directory, "convbin")
    rnx2rtkp_path = os.path.join(directory, "rnx2rtkp")
    write_fake_tool(convbin_path, FAKE_CONVBIN_BODY)
    write_fake_tool(rnx2rtkp_path, FAKE_RNX2RTKP_BODY)
    return convbin_path, rnx2rtkp_path


# ---------------------------------------------------------------------------
# Position file helper
# ---------------------------------------------------------------------------

def make_pos(path, n_fixed, n_float):
    """Write a .pos file with n_float float epochs then n_fixed fixed epochs."""
    start = datetime.datetime(2026, 10, 24, 6, 0, 0)
    lines = []
    for i in range(n_float + n_fixed):
        dt = start + datetime.timedelta(seconds=i)
        ts = dt.strftime("%Y/%m/%d %H:%M:%S.000")
        d = (i % 5) - 2
        lat = 42.65236966 + d * 1e-9
        lon = 26.43258495 + d * 1e-9
        h = 208.145 + d * 0.001
        if i < n_float:
            q = 2
            sdn = sde = sdu = 0.01
        else:
            q = 1
            sdn = sde = sdu = 0.001
        line = (
            f"{ts} {lat:.9f} {lon:.9f} {h:.4f} {q} 8 "
            f"{sdn:.3f} {sde:.3f} {sdu:.3f} 0 0 0 0 0"
        )
        lines.append(line)
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


# ---------------------------------------------------------------------------
# Account helper
# ---------------------------------------------------------------------------

def ACCOUNT(port, mountpoint="MP1", mode="vrs", user="u1", password="p1"):
    """Create a test account dict."""
    return {
        "id": "acc1",
        "name": "Net A",
        "host": "127.0.0.1",
        "port": port,
        "mountpoint": mountpoint,
        "username": user,
        "password": password,
        "tls": False,
        "mode": mode,
        "frame": "ETRF2000@2005.0",
        "epoch": None,
    }


# ---------------------------------------------------------------------------
# Port helper
# ---------------------------------------------------------------------------

def free_port():
    """Bind to port 0, read the assigned port, close, return it."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port
