#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export GM_REPO_ROOT="$REPO"
python3 << 'PYEOF'
import os, sys, struct, time, threading, socket, random, tempfile

repo = os.environ["GM_REPO_ROOT"]
sys.path.insert(0, repo)
sys.path.insert(0, os.path.join(repo, "tests"))
import cors_fakes as cf
cf.install_stubs()
from addons.features.cors_position import cors_rtk as cr

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

def ubx_frame(cls, mid, payload):
    data = bytes([cls, mid]) + struct.pack("<H", len(payload)) + payload
    ck_a = 0
    ck_b = 0
    for b in data:
        ck_a = (ck_a + b) & 0xFF
        ck_b = (ck_b + ck_a) & 0xFF
    return b"\xb5\x62" + data + bytes([ck_a, ck_b])

def nav_pvt(lat_deg, lon_deg, h_ellipsoid_m, fix_type=3, flags=1):
    payload = bytearray(92)
    struct.pack_into("<B", payload, 20, fix_type)
    struct.pack_into("<B", payload, 21, flags)
    struct.pack_into("<i", payload, 24, round(lon_deg * 1e7))
    struct.pack_into("<i", payload, 28, round(lat_deg * 1e7))
    struct.pack_into("<i", payload, 32, round(h_ellipsoid_m * 1000))
    struct.pack_into("<i", payload, 36, round((h_ellipsoid_m - 37.6) * 1000))
    return ubx_frame(0x01, 0x07, bytes(payload))

def serve(chunks, delay=0.05, hold=0.5):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    port = server.getsockname()[1]
    def handler():
        try:
            conn, _ = server.accept()
            for chunk in chunks:
                conn.sendall(chunk)
                time.sleep(delay)
            time.sleep(hold)
            conn.close()
        except Exception:
            pass
        finally:
            server.close()
    t = threading.Thread(target=handler, daemon=True)
    t.start()
    return port

def test_a():
    frame1 = nav_pvt(42.0, 26.0, 100.0)
    frame2 = ubx_frame(0x02, 0x15, b"\x00" * 16)
    buf = b"garbage" + frame1 + b"more noise" + frame2 + b"end"
    frames, rest = cr._iter_ubx_frames(buf)
    assert len(frames) == 2, f"expected 2 frames, got {len(frames)}"
    assert frames[0][0] == 0x01 and frames[0][1] == 0x07
    assert len(frames[0][2]) == 92
    assert frames[1][0] == 0x02 and frames[1][1] == 0x15
    assert len(frames[1][2]) == 16
    assert rest == b"", f"trailing noise must be consumed, got {rest!r}"
test("A _iter_ubx_frames basics", test_a)

def test_b():
    frame = nav_pvt(42.0, 26.0, 100.0)
    for cut in range(1, len(frame)):
        first = frame[:cut]
        second = frame[cut:]
        frames1, rest1 = cr._iter_ubx_frames(first)
        assert len(frames1) == 0, f"cut {cut}: expected 0 frames from first part"
        frames2, rest2 = cr._iter_ubx_frames(rest1 + second)
        assert len(frames2) == 1, f"cut {cut}: expected 1 frame from combined"
        assert rest2 == b""
test("B partial and split frames", test_b)

def test_c():
    frames, rest = cr._iter_ubx_frames(b"\xb5")
    assert len(frames) == 0
    assert rest == b"\xb5"
    frame = nav_pvt(42.0, 26.0, 100.0)
    bad = frame[:-2] + b"\xff\xff"
    frames, rest = cr._iter_ubx_frames(bad)
    assert len(frames) == 0
    header = b"\xb5\x62\x01\x07" + struct.pack("<H", 60000) + b"\x00" * 10
    frames, rest = cr._iter_ubx_frames(header)
    assert len(frames) == 0
    rng = random.Random(1)
    data = rng.randbytes(5000)
    frames, rest = cr._iter_ubx_frames(data)
    assert len(frames) == 0
test("C robustness", test_c)

def test_d():
    noise = b"\x00\x01\x02\x03" * 10
    bad_fix = nav_pvt(40.0, 20.0, 50.0, fix_type=2)
    bad_flags = nav_pvt(40.0, 20.0, 50.0, flags=0)
    good = nav_pvt(42.65236966, 26.43258495, 208.145)
    port = serve([noise, bad_fix, bad_flags, good], delay=0.05, hold=0.5)
    time.sleep(0.1)
    lat, lon, h = cr.read_approx_from_ubx("127.0.0.1", port, timeout=5.0)
    assert abs(lat - 42.65236966) < 1e-7, f"lat {lat}"
    assert abs(lon - 26.43258495) < 1e-7, f"lon {lon}"
    assert abs(h - 208.145) < 0.001, f"h {h}"
test("D read_approx_from_ubx success", test_d)

def test_e():
    frame = nav_pvt(42.65236966, 26.43258495, 208.145)
    chunk_size = len(frame) // 3
    chunks = [frame[i:i+chunk_size] for i in range(0, len(frame), chunk_size)]
    port = serve(chunks, delay=0.05, hold=0.5)
    time.sleep(0.1)
    lat, lon, h = cr.read_approx_from_ubx("127.0.0.1", port, timeout=5.0)
    assert abs(lat - 42.65236966) < 1e-7
    assert abs(lon - 26.43258495) < 1e-7
    assert abs(h - 208.145) < 0.001
test("E split across TCP segments", test_e)

def test_f():
    bad = nav_pvt(40.0, 20.0, 50.0, fix_type=1)
    port = serve([bad, bad, bad], delay=0.1, hold=0.5)
    time.sleep(0.1)
    try:
        cr.read_approx_from_ubx("127.0.0.1", port, timeout=1.5)
        assert False, "expected CorsRtkError"
    except cr.CorsRtkError as e:
        assert e.kind == "no_approx_position"
        assert e.stage == "approx"
    refused = cf.free_port()
    try:
        cr.read_approx_from_ubx("127.0.0.1", refused, timeout=1.0)
        assert False, "expected CorsRtkError"
    except cr.CorsRtkError as e:
        assert e.kind == "no_approx_position"
test("F no fix", test_f)

def test_g():
    receiver = cf.FakeReceiver()
    receiver.start()
    time.sleep(0.5)
    bad = nav_pvt(40.0, 20.0, 50.0, fix_type=1)
    ubx_port = serve([bad, bad], delay=0.1, hold=1.0)
    time.sleep(0.1)
    orig = cr.read_approx_from_ubx
    def fast_ubx(host, port, timeout=60.0):
        return orig(host, port, timeout=1.0)
    cr.read_approx_from_ubx = fast_ubx
    try:
        lat, lon, h = cr._read_approx("127.0.0.1", ubx_port, ".ubx", "127.0.0.1", receiver.nmea_port)
        assert abs(lat - 42.6524) < 0.001, f"lat {lat}"
        assert abs(h - (170.5 + 37.6)) < 0.1, f"h {h}"
    finally:
        cr.read_approx_from_ubx = orig
    def raise_ubx(host, port, timeout=60.0):
        raise AssertionError("UBX should not be called")
    cr.read_approx_from_ubx = raise_ubx
    try:
        lat, lon, h = cr._read_approx("127.0.0.1", ubx_port, ".unicore", "127.0.0.1", receiver.nmea_port)
        assert abs(lat - 42.6524) < 0.001
    finally:
        cr.read_approx_from_ubx = orig
        receiver.stop()
test("G fallback in _read_approx", test_g)

def test_h():
    caster = cf.FakeCaster()
    caster.start()
    receiver = cf.FakeReceiver(silent_nmea=True)
    receiver.start()
    time.sleep(0.5)
    frame = nav_pvt(42.6524, 26.4326, 208.0)
    chunks = [frame] * 20
    ubx_port = serve(chunks, delay=0.2, hold=4.0)
    time.sleep(0.1)
    with tempfile.TemporaryDirectory() as tmpdir:
        convbin, rnx2rtkp = cf.make_tools(tmpdir)
        pos_file = os.path.join(tmpdir, "result.pos")
        cf.make_pos(pos_file, 150, 20)
        os.environ["FAKE_POS_SRC"] = pos_file
        account = cf.ACCOUNT(caster.port)
        params = {
            "duration_s": 1.0,
            "rover_host": "127.0.0.1",
            "rover_port": ubx_port,
            "rover_suffix": ".ubx",
            "nmea_host": "127.0.0.1",
            "nmea_port": receiver.nmea_port,
            "convbin_path": convbin,
            "rnx2rtkp_path": rnx2rtkp,
            "cleanup": False,
        }
        result = cr.compute_position(account, tmpdir, params)
        assert result["approx"] is not None, "approx not set"
        assert abs(result["approx"][0] - 42.6524) < 1e-6, f"lat {result['approx'][0]}"
        assert abs(result["approx"][1] - 26.4326) < 1e-6, f"lon {result['approx'][1]}"
        assert abs(result["approx"][2] - 208.0) < 0.001, f"h {result['approx'][2]}"
    caster.stop()
    receiver.stop()
test("H compute_position uses UBX", test_h)

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(failed)
PYEOF
exit $?
