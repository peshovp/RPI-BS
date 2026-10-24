#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export GM_REPO_ROOT="$REPO"
python3 << 'PYEOF'
import os, sys, json, re, time, tempfile, threading
from pathlib import Path

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
        print(f"PASS: {name}")
        passed += 1
    except Exception as e:
        print(f"FAIL: {name}: {e}")
        failed += 1

def run(tmp, *, mode="vrs", mountpoint="MP1", user="u1", password="p1",
        pos=(150, 20), env=None, extra=None, caster_kwargs=None,
        receiver_kwargs=None, work_name="work"):
    if caster_kwargs is None:
        caster_kwargs = {}
    if receiver_kwargs is None:
        receiver_kwargs = {}
    if extra is None:
        extra = {}
    caster = cf.FakeCaster(**caster_kwargs)
    receiver = cf.FakeReceiver(**receiver_kwargs)
    caster.start()
    receiver.start()
    convbin, rnx2rtkp = cf.make_tools(tmp)
    saved = {}
    if pos is not None:
        src = os.path.join(tmp, "src.pos")
        cf.make_pos(src, *pos)
        saved["FAKE_POS_SRC"] = os.environ.get("FAKE_POS_SRC")
        os.environ["FAKE_POS_SRC"] = src
    if env:
        for k, v in env.items():
            saved[k] = os.environ.get(k)
            os.environ[k] = v
    params = {
        "duration_s": 2.0,
        "rover_host": "127.0.0.1",
        "rover_port": receiver.raw_port,
        "nmea_host": "127.0.0.1",
        "nmea_port": receiver.nmea_port,
        "convbin_path": convbin,
        "rnx2rtkp_path": rnx2rtkp,
        "min_used": 60, "ubx_timeout": 1.0,
    }
    params.update(extra)
    try:
        result = cr.compute_position(
            cf.ACCOUNT(caster.port, mountpoint, mode, user, password),
            os.path.join(tmp, work_name),
            params
        )
    finally:
        caster.stop()
        receiver.stop()
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
    return result, caster, receiver

def test_a():
    with tempfile.TemporaryDirectory() as tmp:
        receiver = cf.FakeReceiver()
        receiver.start()
        try:
            lat, lon, h = cr.read_approx_from_nmea("127.0.0.1", receiver.nmea_port)
            assert abs(lat - 42.6524) < 1e-6
            assert abs(lon - 26.4326) < 1e-6
            assert abs(h - (170.5 + 37.6)) < 1e-6
        finally:
            receiver.stop()
        receiver2 = cf.FakeReceiver(silent_nmea=True)
        receiver2.start()
        try:
            try:
                cr.read_approx_from_nmea("127.0.0.1", receiver2.nmea_port, timeout=1.5)
                assert False, "expected error"
            except cr.CorsRtkError as e:
                assert e.kind == "no_approx_position"
                assert e.stage == "approx"
        finally:
            receiver2.stop()
        port = cf.free_port()
        try:
            cr.read_approx_from_nmea("127.0.0.1", port, timeout=1.0)
            assert False, "expected error"
        except cr.CorsRtkError as e:
            assert e.kind == "no_approx_position"

def test_b():
    with tempfile.TemporaryDirectory() as tmp:
        receiver = cf.FakeReceiver()
        receiver.start()
        try:
            out = os.path.join(tmp, "raw.ubx")
            info = cr.capture_local_raw("127.0.0.1", receiver.raw_port, out, 1.0)
            assert info["bytes"] > 0
            with open(out, "rb") as f:
                data = f.read()
            assert len(data) % 6 == 0
            assert data == b"UBXRAW" * (len(data) // 6)
            import stat
            st = os.stat(out)
            assert stat.S_IMODE(st.st_mode) == 0o600
        finally:
            receiver.stop()
        receiver2 = cf.FakeReceiver(silent_raw=True)
        receiver2.start()
        try:
            out2 = os.path.join(tmp, "raw2.ubx")
            try:
                cr.capture_local_raw("127.0.0.1", receiver2.raw_port, out2, 5.0, idle_timeout=1.0)
                assert False, "expected error"
            except cr.CorsRtkError as e:
                assert e.stage == "capture_rover"
                assert e.kind == "no_data"
        finally:
            receiver2.stop()
        port = cf.free_port()
        try:
            cr.capture_local_raw("127.0.0.1", port, os.path.join(tmp, "raw3.ubx"), 1.0)
            assert False, "expected error"
        except cr.CorsRtkError as e:
            assert e.kind == "connect"
        receiver3 = cf.FakeReceiver()
        receiver3.start()
        try:
            ev = threading.Event()
            def set_ev():
                time.sleep(0.5)
                ev.set()
            threading.Thread(target=set_ev, daemon=True).start()
            start = time.time()
            info3 = cr.capture_local_raw("127.0.0.1", receiver3.raw_port,
                                         os.path.join(tmp, "raw4.ubx"), 20.0,
                                         stop_event=ev)
            elapsed = time.time() - start
            assert elapsed < 3.0
        finally:
            receiver3.stop()

def test_c():
    with tempfile.TemporaryDirectory() as tmp:
        convbin, _ = cf.make_tools(tmp)
        raw = os.path.join(tmp, "test.ubx")
        with open(raw, "wb") as f:
            f.write(b"UBXRAW" * 100)
        out_dir = os.path.join(tmp, "out")
        obs, nav = cr.convert_obs(convbin, raw, out_dir, "ubx")
        assert obs.exists()
        assert len(nav) == 1
        os.environ["FAKE_CONVBIN_MODE"] = "fail"
        try:
            cr.convert_obs(convbin, raw, os.path.join(tmp, "out2"), "ubx")
            assert False, "expected error"
        except cr.CorsRtkError as e:
            assert e.kind == "convert_failed"
        finally:
            del os.environ["FAKE_CONVBIN_MODE"]
        os.environ["FAKE_CONVBIN_MODE"] = "nofile"
        try:
            cr.convert_obs(convbin, raw, os.path.join(tmp, "out3"), "ubx")
            assert False, "expected error"
        except cr.CorsRtkError as e:
            assert e.kind == "convert_failed"
        finally:
            del os.environ["FAKE_CONVBIN_MODE"]
        # stale output from the first successful run must not be accepted
        os.environ["FAKE_CONVBIN_MODE"] = "nofile"
        try:
            cr.convert_obs(convbin, raw, out_dir, "ubx")
            assert False, "expected error"
        except cr.CorsRtkError as e:
            assert e.kind == "convert_failed"
        finally:
            del os.environ["FAKE_CONVBIN_MODE"]
        os.environ["FAKE_CONVBIN_MODE"] = "sleep"
        try:
            start = time.time()
            cr.convert_obs(convbin, raw, os.path.join(tmp, "out4"), "ubx", timeout=1)
            assert False, "expected timeout"
        except cr.CorsRtkError as e:
            assert e.kind == "timeout"
            assert time.time() - start < 8.0
        finally:
            del os.environ["FAKE_CONVBIN_MODE"]

def test_d():
    with tempfile.TemporaryDirectory() as tmp:
        _, rnx2rtkp = cf.make_tools(tmp)
        src = os.path.join(tmp, "src.pos")
        cf.make_pos(src, 150, 20)
        os.environ["FAKE_POS_SRC"] = src
        obs1 = os.path.join(tmp, "r.obs")
        obs2 = os.path.join(tmp, "b.obs")
        with open(obs1, "w") as f:
            f.write("ROVER OBS\n")
        with open(obs2, "w") as f:
            f.write("BASE OBS\n")
        out_pos = Path(os.path.join(tmp, "result.pos"))
        cr.run_rnx2rtkp(rnx2rtkp, Path(obs1), Path(obs2), [], "pos1-posmode 1\n", out_pos)
        assert out_pos.exists()
        assert out_pos.stat().st_size > 0
        conf_path = Path(str(out_pos) + ".conf")
        assert conf_path.exists()
        import stat
        st = os.stat(conf_path)
        assert stat.S_IMODE(st.st_mode) == 0o600
        assert "pos1-posmode" in conf_path.read_text()
        os.environ["FAKE_RNX_MODE"] = "fail"
        try:
            cr.run_rnx2rtkp(rnx2rtkp, Path(obs1), Path(obs2), [], "pos1-posmode 1\n", out_pos)
            assert False, "expected error"
        except cr.CorsRtkError as e:
            assert e.kind == "solve_failed"
        finally:
            del os.environ["FAKE_RNX_MODE"]
        os.environ["FAKE_RNX_MODE"] = "nofile"
        try:
            cr.run_rnx2rtkp(rnx2rtkp, Path(obs1), Path(obs2), [], "pos1-posmode 1\n", out_pos)
            assert False, "expected error"
        except cr.CorsRtkError as e:
            assert e.kind == "solve_failed"
        finally:
            del os.environ["FAKE_RNX_MODE"]
        # a stale output file must not be accepted
        cr.run_rnx2rtkp(rnx2rtkp, Path(obs1), Path(obs2), [], "pos1-posmode 1\n", out_pos)
        assert out_pos.exists()
        os.environ["FAKE_RNX_MODE"] = "nofile"
        try:
            cr.run_rnx2rtkp(rnx2rtkp, Path(obs1), Path(obs2), [], "pos1-posmode 1\n", out_pos)
            assert False, "expected error"
        except cr.CorsRtkError as e:
            assert e.kind == "solve_failed"
        finally:
            del os.environ["FAKE_RNX_MODE"]
        del os.environ["FAKE_POS_SRC"]

def test_e():
    with tempfile.TemporaryDirectory() as tmp:
        result, caster, receiver = run(tmp)
        assert result["ok"] is True
        assert result["stage"] is None
        assert result["kind"] is None
        assert result["reason"] is None
        assert abs(result["lat"] - 42.65236966) < 1e-8
        assert abs(result["lon"] - 26.43258495) < 1e-8
        assert abs(result["h"] - 208.145) < 0.002
        assert abs(result["base_xyz"][0] - 4178200.1234) < 1e-4
        assert abs(result["base_xyz"][1] - 2084711.5678) < 1e-4
        assert abs(result["base_xyz"][2] - 4328800.9876) < 1e-4
        assert result["rover_bytes"] > 0
        assert result["base_bytes"] > 0
        assert result["summary"]["fixed"] == 150
        assert abs(result["approx"][0] - 42.6524) < 1e-6
        assert abs(result["approx"][1] - 26.4326) < 1e-6
        assert b"$GPGGA," in caster.after_headers
        assert not os.path.exists(os.path.join(tmp, "work"))
        j = json.dumps(result)
        assert "127.0.0.1" not in j
        assert "MP1" not in j
        assert "u1" not in j
        assert re.search(r"\bp1\b", j) is None

def test_f():
    with tempfile.TemporaryDirectory() as tmp:
        result, caster, receiver = run(tmp, mode="single_base")
        assert result["ok"] is True
        assert b"$GPGGA" not in caster.after_headers

def test_g():
    with tempfile.TemporaryDirectory() as tmp:
        result, _, _ = run(tmp, password="wrong")
        assert result["ok"] is False
        assert result["stage"] == "capture_base"
        assert result["kind"] == "auth"
    with tempfile.TemporaryDirectory() as tmp:
        result, _, _ = run(tmp, env={"FAKE_NO_BASE_POS": "1"})
        assert result["ok"] is False
        assert result["stage"] == "convert"
        assert result["kind"] == "no_base_position"
    with tempfile.TemporaryDirectory() as tmp:
        result, _, _ = run(tmp, pos=(0, 100))
        assert result["ok"] is False
        assert result["stage"] == "evaluate"
        assert result["kind"] == "poor_solution"
        assert result["reason"] == "no fixed solution"
        assert result["summary"] is not None
    with tempfile.TemporaryDirectory() as tmp:
        result, _, _ = run(tmp, pos=(30, 0))
        assert result["ok"] is False
        assert result["reason"] == "too few fixed epochs"
    with tempfile.TemporaryDirectory() as tmp:
        result, _, _ = run(tmp, env={"FAKE_CONVBIN_MODE": "fail"})
        assert result["ok"] is False
        assert result["stage"] == "convert"
        assert result["kind"] == "convert_failed"
    with tempfile.TemporaryDirectory() as tmp:
        result, _, _ = run(tmp, extra={"convbin_path": "/nonexistent/convbin"})
        assert result["ok"] is False

def test_h():
    with tempfile.TemporaryDirectory() as tmp:
        result, _, _ = run(tmp, mountpoint="AUTO")
        assert result["ok"] is True
    with tempfile.TemporaryDirectory() as tmp:
        result, _, _ = run(tmp, mountpoint="AUTO",
                          caster_kwargs={"sourcetable_lines": [
                              "STR;MP2;Far;RTCM 3.2;1004(1);2;GPS;NET;BGR;50.0;10.0;0;0;sNTRIP;none;B;N;9600;"]})
        assert result["ok"] is False
        assert result["stage"] == "mountpoint"
        assert result["kind"] == "not_found"
    with tempfile.TemporaryDirectory() as tmp:
        result, _, _ = run(tmp, mountpoint="AUTO", password="wrong")
        assert result["ok"] is False
        assert result["stage"] == "mountpoint"
        assert result["kind"] == "auth"

def test_i():
    with tempfile.TemporaryDirectory() as tmp:
        caster = cf.FakeCaster()
        receiver = cf.FakeReceiver()
        caster.start()
        receiver.start()
        convbin, rnx2rtkp = cf.make_tools(tmp)
        src = os.path.join(tmp, "src.pos")
        cf.make_pos(src, 150, 20)
        os.environ["FAKE_POS_SRC"] = src
        ev = threading.Event()
        def set_ev():
            time.sleep(1.0)
            ev.set()
        threading.Thread(target=set_ev, daemon=True).start()
        params = {
            "duration_s": 30.0,
            "rover_host": "127.0.0.1",
            "rover_port": receiver.raw_port,
            "nmea_host": "127.0.0.1",
            "nmea_port": receiver.nmea_port,
            "convbin_path": convbin,
            "rnx2rtkp_path": rnx2rtkp,
            "min_used": 60, "ubx_timeout": 1.0,
        }
        start = time.time()
        result = cr.compute_position(
            cf.ACCOUNT(caster.port, "MP1", "vrs", "u1", "p1"),
            os.path.join(tmp, "work"),
            params,
            stop_event=ev
        )
        elapsed = time.time() - start
        caster.stop()
        receiver.stop()
        del os.environ["FAKE_POS_SRC"]
        assert elapsed < 6.0
        assert result["ok"] is False
        assert result["stage"] == "capture"
        assert result["kind"] == "cancelled"

def test_j():
    with tempfile.TemporaryDirectory() as tmp:
        result, _, _ = run(tmp, extra={"cleanup": False})
        work = os.path.join(tmp, "work")
        assert os.path.exists(work)
        assert os.path.exists(os.path.join(work, "result.pos"))
    with tempfile.TemporaryDirectory() as tmp:
        result, _, _ = run(tmp)
        assert not os.path.exists(os.path.join(tmp, "work"))

def test_k():
    with tempfile.TemporaryDirectory() as tmp:
        result, caster, _ = run(tmp, extra={"approx": (42.65, 26.43, 200.0)},
                               receiver_kwargs={"silent_nmea": True})
        assert result["ok"] is True
        assert b"4239.0" in caster.after_headers

test("A: read_approx_from_nmea", test_a)
test("B: capture_local_raw", test_b)
test("C: convert_obs", test_c)
test("D: run_rnx2rtkp", test_d)
test("E: success vrs", test_e)
test("F: single_base", test_f)
test("G: failures", test_g)
test("H: AUTO mountpoint", test_h)
test("I: cancel", test_i)
test("J: cleanup flag", test_j)
test("K: approx param", test_k)

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(failed)
PYEOF
exit $?
