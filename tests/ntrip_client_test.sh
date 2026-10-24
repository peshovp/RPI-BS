#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${GM_REPO_ROOT:-$(dirname "$SCRIPT_DIR")}"

if ! command -v python3 &>/dev/null; then
    echo "SKIP: python3 not found"
    exit 0
fi

export GM_REPO_ROOT="$REPO"

python3 << 'PYEOF'
import os
import sys
import json
import time
import socket
import threading
import base64
import tempfile
import stat
import re
from datetime import datetime

repo_root = os.environ.get('GM_REPO_ROOT', '.')
sys.path.insert(0, os.path.join(repo_root, 'addons', 'features', 'cors_position'))

import ntrip_client as nc

passed = 0
failed = 0

def test(name, fn):
    global passed, failed
    try:
        fn()
        passed += 1
        print(f"PASS: {name}")
    except Exception as e:
        failed += 1
        print(f"FAIL: {name}: {e}")

DEFAULT_SOURCETABLE = [
    "STR;MP1;Sofia;RTCM 3.2;1004(1),1005(10);2;GPS+GLO;NET;BGR;42.70;23.32;1;0;sNTRIP;none;B;N;9600;",
    "STR;MP2;Plovdiv;RTCM 3.2;1004(1);2;GPS;NET;BGR;42.15;24.75;0;0;sNTRIP;none;B;N;9600;",
    "STR;MP3;Varna;RTCM 3.2;1004(1);2;GPS;NET;BGR;43.20;27.92;1;0;sNTRIP;none;B;N;9600;",
    "STR;BAD;x;RTCM 3.2;;2;GPS;NET;BGR;notnum;23.0;1;0;",
    "CAS;host;2101;x"
]

class FakeCaster:
    def __init__(self, user="u1", password="p1", mountpoints=None, version=1,
                 chunked=False, stream_chunks=None, delay=0.0, first_delay=0.0,
                 close_after=True, split_chunks=False, sourcetable_lines=None):
        self.user = user
        self.password = password
        self.mountpoints = mountpoints or {"MP1"}
        self.version = version
        self.chunked = chunked
        self.stream_chunks = stream_chunks or []
        self.delay = delay
        self.first_delay = first_delay
        self.close_after = close_after
        self.split_chunks = split_chunks
        self.sourcetable_lines = sourcetable_lines or DEFAULT_SOURCETABLE
        self.requests = []
        self.received_after_headers = b""
        self._lock = threading.Lock()
        self._server = None
        self._port = None
        self._running = False
        self._threads = []
        self._stopped = threading.Event()

    def start(self):
        self._server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._server.bind(("127.0.0.1", 0))
        self._port = self._server.getsockname()[1]
        self._server.listen(5)
        self._running = True
        self._stopped.clear()
        accept_thread = threading.Thread(target=self._accept_loop, daemon=True)
        accept_thread.start()
        self._threads.append(accept_thread)
        return self._port

    def stop(self):
        self._running = False
        self._stopped.set()
        if self._server:
            try:
                self._server.close()
            except Exception:
                pass
        for t in self._threads:
            t.join(timeout=2)
        self._threads = []

    def _accept_loop(self):
        while self._running:
            try:
                self._server.settimeout(0.5)
                conn, addr = self._server.accept()
            except socket.timeout:
                continue
            except Exception:
                break
            t = threading.Thread(target=self._handle_connection, args=(conn,), daemon=True)
            t.start()
            self._threads.append(t)

    def _handle_connection(self, conn):
        try:
            conn.settimeout(5)
            data = b""
            while b"\r\n\r\n" not in data:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                data += chunk

            header_end = data.find(b"\r\n\r\n")
            header_text = data[:header_end].decode("utf-8", errors="replace")
            leftover = data[header_end + 4:]

            lines = header_text.split("\r\n")
            request_line = lines[0]
            headers = {}
            for line in lines[1:]:
                if ":" in line:
                    name, value = line.split(":", 1)
                    headers[name.strip().lower()] = value.strip()

            parts = request_line.split(" ")
            path = parts[1] if len(parts) > 1 else "/"

            auth = headers.get("authorization", "")
            user = self.user
            password = self.password
            if auth.startswith("Basic "):
                try:
                    decoded = base64.b64decode(auth[6:]).decode("utf-8")
                    u, p = decoded.split(":", 1)
                    user = u
                    password = p
                except Exception:
                    pass

            with self._lock:
                self.requests.append({
                    "path": path,
                    "authorization": auth
                })

            if user != self.user or password != self.password:
                if self.version == 1:
                    conn.sendall(b"HTTP/1.1 401 Unauthorized\r\n\r\n")
                else:
                    conn.sendall(b"HTTP/1.1 401 Unauthorized\r\n\r\n")
                return

            if path == "/":
                self._send_sourcetable(conn)
            elif path.startswith("/") and path[1:] in self.mountpoints:
                self._send_stream(conn, leftover)
            else:
                self._send_sourcetable(conn)
        except Exception:
            pass
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def _send_sourcetable(self, conn):
        if self.version == 1:
            conn.sendall(b"SOURCETABLE 200 OK\r\nContent-Type: text/plain\r\n\r\n")
        else:
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: gnss/sourcetable\r\nConnection: close\r\n\r\n")

        for line in self.sourcetable_lines:
            conn.sendall((line + "\r\n").encode("utf-8"))
        conn.sendall(b"ENDSOURCETABLE\r\n")

    def _send_stream(self, conn, leftover):
        if self.version == 1:
            conn.sendall(b"ICY 200 OK\r\n\r\n")
        else:
            response = b"HTTP/1.1 200 OK\r\nNtrip-Version: Ntrip/2.0\r\nContent-Type: gnss/data\r\n"
            if self.chunked:
                response += b"Transfer-Encoding: chunked\r\n"
            response += b"\r\n"
            conn.sendall(response)

        if leftover:
            with self._lock:
                self.received_after_headers += leftover

        reader_thread = threading.Thread(target=self._read_client, args=(conn,), daemon=True)
        reader_thread.start()
        self._threads.append(reader_thread)

        if self.first_delay > 0:
            time.sleep(self.first_delay)

        for i, chunk in enumerate(self.stream_chunks):
            if i > 0 and self.delay > 0:
                time.sleep(self.delay)
            if self.chunked:
                size_line = f"{len(chunk):X}\r\n".encode("ascii")
                chunk_data = size_line + chunk + b"\r\n"
                if self.split_chunks:
                    mid = len(chunk_data) // 2
                    conn.sendall(chunk_data[:mid])
                    time.sleep(0.05)
                    conn.sendall(chunk_data[mid:])
                else:
                    conn.sendall(chunk_data)
            else:
                conn.sendall(chunk)

        if self.chunked and self.close_after:
            conn.sendall(b"0\r\n\r\n")

        if not self.close_after:
            time.sleep(10)

    def _read_client(self, conn):
        try:
            conn.settimeout(0.5)
            while not self._stopped.is_set():
                try:
                    data = conn.recv(4096)
                except socket.timeout:
                    continue
                except Exception:
                    break
                if not data:
                    break
                with self._lock:
                    self.received_after_headers += data
        except Exception:
            pass

def test_a():
    caster = FakeCaster(version=1)
    port = caster.start()
    try:
        entries = nc.fetch_sourcetable("127.0.0.1", port, "u1", "p1")
        assert len(entries) == 3, f"Expected 3 entries, got {len(entries)}"
        mp1 = [e for e in entries if e["mountpoint"] == "MP1"][0]
        assert mp1["lat"] == 42.7, f"MP1 lat wrong: {mp1['lat']}"
        assert mp1["lon"] == 23.32, f"MP1 lon wrong: {mp1['lon']}"
        assert mp1["nmea"] is True, "MP1 nmea should be True"
        mp2 = [e for e in entries if e["mountpoint"] == "MP2"][0]
        assert mp2["nmea"] is False, "MP2 nmea should be False"
    finally:
        caster.stop()

test("A: sourcetable v1 returns 3 entries with correct fields", test_a)

def test_b():
    caster = FakeCaster(version=2)
    port = caster.start()
    try:
        entries = nc.fetch_sourcetable("127.0.0.1", port, "u1", "p1")
        assert len(entries) == 3, f"Expected 3 entries, got {len(entries)}"
        mountpoints = [e["mountpoint"] for e in entries]
        assert "MP1" in mountpoints and "MP2" in mountpoints and "MP3" in mountpoints
    finally:
        caster.stop()

test("B: sourcetable v2 returns same 3 entries", test_b)

def test_c():
    caster = FakeCaster()
    port = caster.start()
    try:
        try:
            nc.fetch_sourcetable("127.0.0.1", port, "wrong", "wrong")
            assert False, "Should have raised"
        except nc.NtripError as e:
            assert e.kind == "auth", f"Expected auth error, got {e.kind}"
            msg = str(e)
            assert "p1" not in msg and "u1" not in msg and "MP1" not in msg and "127.0.0.1" not in msg

        try:
            with tempfile.TemporaryDirectory() as d:
                out = os.path.join(d, "out.ubx")
                nc.capture_stream("127.0.0.1", port, "MP1", "wrong", "wrong", out, 1)
                assert False, "Should have raised"
        except nc.NtripError as e:
            assert e.kind == "auth", f"Expected auth error, got {e.kind}"
    finally:
        caster.stop()

test("C: bad credentials raise auth error without secrets", test_c)

def test_d():
    entries = [
        {"mountpoint": "MP1", "format": "RTCM 3.2", "lat": 42.70, "lon": 23.32, "nmea": True},
        {"mountpoint": "MP2", "format": "RTCM 3.2", "lat": 42.15, "lon": 24.75, "nmea": False},
        {"mountpoint": "MP3", "format": "RTCM 3.2", "lat": 43.20, "lon": 27.92, "nmea": True},
    ]
    result = nc.pick_mountpoint(entries, 42.65, 26.43, need_nmea=True)
    assert result is not None, "Should find a mountpoint"
    assert result["mountpoint"] == "MP3", f"Expected MP3, got {result['mountpoint']}"

    result2 = nc.pick_mountpoint(entries, 42.65, 26.43, need_nmea=False)
    assert result2 is not None
    assert result2["mountpoint"] == "MP3", f"Expected MP3, got {result2['mountpoint']}"

    assert nc.pick_mountpoint([], 1, 1) is None

    raw_entries = [{"mountpoint": "X", "format": "RAW", "lat": 1, "lon": 1, "nmea": True}]
    assert nc.pick_mountpoint(raw_entries, 1, 1) is None

test("D: pick_mountpoint selects nearest correctly", test_d)

def test_e():
    chunks = [b"A" * 1000, b"B" * 1000, b"C" * 500]
    caster = FakeCaster(version=1, stream_chunks=chunks, delay=0.2, close_after=True)
    port = caster.start()
    try:
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "out.ubx")
            result = nc.capture_stream("127.0.0.1", port, "MP1", "u1", "p1", out, 5)
            assert result["bytes"] == 2500, f"Expected 2500 bytes, got {result['bytes']}"
            with open(out, "rb") as f:
                content = f.read()
            assert content == b"".join(chunks), "File content mismatch"
            mode = os.stat(out).st_mode & 0o777
            assert mode == 0o600, f"Expected mode 0600, got {oct(mode)}"
            assert "bytes" in result and "seconds" in result and "first_data_s" in result and "mountpoint" in result
            assert result["seconds"] < 4, f"Expected < 4s, got {result['seconds']}"
    finally:
        caster.stop()

test("E: capture v1 plain stream works", test_e)

def test_f():
    payload = b"chunked data payload here"
    chunks = [payload]
    caster = FakeCaster(version=2, chunked=True, stream_chunks=chunks, split_chunks=True, close_after=True)
    port = caster.start()
    try:
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "out.ubx")
            result = nc.capture_stream("127.0.0.1", port, "MP1", "u1", "p1", out, 5)
            with open(out, "rb") as f:
                content = f.read()
            assert content == payload, f"Expected {payload!r}, got {content!r}"
    finally:
        caster.stop()

test("F: capture v2 chunked with split chunks works", test_f)

def test_g():
    caster = FakeCaster(version=1, stream_chunks=[b"X" * 100], close_after=False)
    port = caster.start()
    try:
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "out.ubx")
            result = nc.capture_stream(
                "127.0.0.1", port, "MP1", "u1", "p1", out, 2,
                gga_provider=lambda: nc.make_gga(42.65, 26.43, 208.1),
                gga_interval_s=0.5
            )
            time.sleep(0.5)
            with caster._lock:
                received = caster.received_after_headers
            gga_matches = re.findall(rb"\$GPGGA,[^\r\n]*\*[0-9A-F]{2}\r\n", received)
            assert len(gga_matches) >= 2, f"Expected >= 2 GGA sentences, got {len(gga_matches)}"
            gga_count = received.count(b"$GPGGA,")
            assert gga_count == len(gga_matches), f"Expected {len(gga_matches)} complete GGA sentences, found {gga_count} occurrences of $GPGGA,"
            for match in gga_matches:
                body = match.decode("ascii")
                data_part = body[1:body.index("*")]
                checksum_str = body[body.index("*") + 1:-2]
                checksum = 0
                for ch in data_part:
                    checksum ^= ord(ch)
                assert f"*{checksum:02X}" == f"*{int(checksum_str, 16):02X}", f"Bad checksum in {body}"
    finally:
        caster.stop()

test("G: GGA sentences are sent and have valid checksums", test_g)

def test_h():
    sentence = nc.make_gga(42.65236966, 26.43258495, 208.145, datetime(2026, 10, 24, 6, 5, 4))
    assert sentence.startswith("$GPGGA,060504.00,4239.14"), f"Bad start: {sentence[:30]}"
    assert ",N,02625.95" in sentence, f"Missing N/lon: {sentence}"
    assert ",E,1,10,1.0,208.145,M," in sentence, f"Missing E/height: {sentence}"
    assert sentence.endswith("\r\n"), "Should end with CRLF"

    body = sentence.strip()
    if "*" in body:
        data_part = body[1:body.index("*")]
        checksum_str = body[body.index("*") + 1:]
        checksum = 0
        for ch in data_part:
            checksum ^= ord(ch)
        assert f"*{checksum:02X}" == f"*{int(checksum_str, 16):02X}", "Bad checksum"

    south = nc.make_gga(-33.5, 151.0, 10.0)
    assert ",S," in south, f"Missing S: {south}"

test("H: make_gga format is correct", test_h)

def test_i():
    caster = FakeCaster(version=1, stream_chunks=[b"data"], first_delay=1.5, close_after=True)
    port = caster.start()
    try:
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "out.ubx")
            result = nc.capture_stream("127.0.0.1", port, "MP1", "u1", "p1", out, 4, idle_timeout=5)
            assert result["bytes"] > 0, "Expected some bytes"
    finally:
        caster.stop()

test("I: silent start with first_delay works", test_i)

def test_j():
    caster = FakeCaster(version=1, stream_chunks=[], close_after=False)
    port = caster.start()
    try:
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "out.ubx")
            start = time.time()
            try:
                nc.capture_stream("127.0.0.1", port, "MP1", "u1", "p1", out, 10, idle_timeout=1.5)
                assert False, "Should have raised"
            except nc.NtripError as e:
                elapsed = time.time() - start
                assert e.kind == "no_data", f"Expected no_data, got {e.kind}"
                assert 1 < elapsed < 5, f"Expected 1-5s, got {elapsed}"
    finally:
        caster.stop()

test("J: no data raises no_data error", test_j)

def test_k():
    caster = FakeCaster(version=1, stream_chunks=[], close_after=True)
    port = caster.start()
    try:
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "out.ubx")
            try:
                nc.capture_stream("127.0.0.1", port, "MP1", "u1", "p1", out, 5)
                assert False, "Should have raised"
            except nc.NtripError as e:
                assert e.kind == "no_data", f"Expected no_data, got {e.kind}"
    finally:
        caster.stop()

test("K: server closes immediately raises no_data", test_k)

def test_l():
    for version in [1, 2]:
        caster = FakeCaster(version=version)
        port = caster.start()
        try:
            with tempfile.TemporaryDirectory() as d:
                out = os.path.join(d, "out.ubx")
                try:
                    nc.capture_stream("127.0.0.1", port, "NOPE", "u1", "p1", out, 2)
                    assert False, "Should have raised"
                except nc.NtripError as e:
                    assert e.kind == "not_found", f"Expected not_found, got {e.kind}"
        finally:
            caster.stop()

test("L: unknown mountpoint raises not_found", test_l)

def test_m():
    # Part (a): connect refused - use a port with no listener
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    unused_port = s.getsockname()[1]
    s.close()

    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "out.ubx")
        try:
            nc.capture_stream("127.0.0.1", unused_port, "MP1", "u1", "p1", out, 1)
            assert False, "Should have raised"
        except nc.NtripError as e:
            assert e.kind == "connect", f"Expected connect, got {e.kind}"

    # Part (b): timeout - server accepts but never sends data
    server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server_sock.bind(("127.0.0.1", 0))
    timeout_port = server_sock.getsockname()[1]
    server_sock.listen(1)

    def hold_connection():
        try:
            conn, _ = server_sock.accept()
            time.sleep(5)
            conn.close()
        except Exception:
            pass

    hold_thread = threading.Thread(target=hold_connection, daemon=True)
    hold_thread.start()

    try:
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "out.ubx")
            start = time.time()
            try:
                nc.capture_stream("127.0.0.1", timeout_port, "MP1", "u1", "p1", out, 10, connect_timeout=1)
                assert False, "Should have raised"
            except nc.NtripError as e:
                elapsed = time.time() - start
                assert e.kind == "timeout", f"Expected timeout, got {e.kind}"
                assert elapsed < 4, f"Expected < 4s, got {elapsed}"
    finally:
        server_sock.close()
        hold_thread.join(timeout=2)

test("M: connect refused and timeout errors", test_m)

def test_n():
    caster = FakeCaster(version=1, stream_chunks=[b"X" * 100], close_after=False)
    port = caster.start()
    try:
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "out.ubx")
            stop_event = threading.Event()
            def set_event():
                time.sleep(1)
                stop_event.set()
            t = threading.Thread(target=set_event, daemon=True)
            t.start()
            start = time.time()
            result = nc.capture_stream("127.0.0.1", port, "MP1", "u1", "p1", out, 30, stop_event=stop_event)
            elapsed = time.time() - start
            assert elapsed < 4, f"Expected < 4s, got {elapsed}"
            assert result["bytes"] > 0, "Expected some bytes"
    finally:
        caster.stop()

test("N: stop_event stops capture", test_n)

def test_o():
    original = b"hello world this is a test"
    chunks = []
    for i in range(0, len(original), 5):
        chunk = original[i:i+5]
        chunks.append(f"{len(chunk):X}\r\n".encode("ascii") + chunk + b"\r\n")
    chunks.append(b"0\r\n\r\n")
    payload = b"".join(chunks)

    decoder1 = nc._ChunkedDecoder()
    result1 = decoder1.feed(payload)

    decoder2 = nc._ChunkedDecoder()
    result2 = b""
    for byte in payload:
        result2 += decoder2.feed(bytes([byte]))

    assert result1 == original, f"Chunked decode failed: {result1!r}"
    assert result2 == original, f"Byte-by-byte decode failed: {result2!r}"

    decoder3 = nc._ChunkedDecoder()
    bad = b"ZZZ\r\n\r\n"
    result3 = decoder3.feed(bad)
    assert isinstance(result3, bytes)

test("O: chunked decoder works correctly", test_o)

def test_p():
    errors = []

    caster = FakeCaster()
    port = caster.start()
    try:
        try:
            nc.fetch_sourcetable("127.0.0.1", port, "wrong", "wrong")
        except nc.NtripError as e:
            errors.append(str(e))
    finally:
        caster.stop()

    caster = FakeCaster(version=1, stream_chunks=[], close_after=True)
    port = caster.start()
    try:
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "out.ubx")
            try:
                nc.capture_stream("127.0.0.1", port, "MP1", "u1", "p1", out, 2)
            except nc.NtripError as e:
                errors.append(str(e))
    finally:
        caster.stop()

    caster = FakeCaster(version=1)
    port = caster.start()
    try:
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "out.ubx")
            try:
                nc.capture_stream("127.0.0.1", port, "NOPE", "u1", "p1", out, 2)
            except nc.NtripError as e:
                errors.append(str(e))
    finally:
        caster.stop()

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    unused_port = s.getsockname()[1]
    s.close()

    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "out.ubx")
        try:
            nc.capture_stream("127.0.0.1", unused_port, "MP1", "u1", "p1", out, 1)
        except nc.NtripError as e:
            errors.append(str(e))

    for err in errors:
        assert "p1" not in err, f"Password in error: {err}"
        assert "u1" not in err, f"Username in error: {err}"
        assert "MP1" not in err, f"Mountpoint in error: {err}"
        assert "127.0.0.1" not in err, f"IP in error: {err}"

test("P: no secrets in error messages", test_p)

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(failed)
PYEOF

exit $?
