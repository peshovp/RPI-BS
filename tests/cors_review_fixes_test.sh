#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export GM_REPO_ROOT="$REPO"
python3 << 'PYEOF'
import os, sys, time, threading, socket, tempfile, shutil, json, re
from unittest import mock

repo = os.environ["GM_REPO_ROOT"]
sys.path.insert(0, repo)
sys.path.insert(0, os.path.join(repo, "tests"))

import cors_fakes as cf
cf.install_stubs()

from addons.features.cors_position import ntrip_client as nc
from addons.features.cors_position import cors_rtk as cr
from addons.features.cors_position import cors_apply as ca
from addons.features.cors_position import cors_job as cj
from addons.features.cors_position import cors_client as cc
from addons.features.cors_position import cors_accounts as acc
from addons.features.auto_survey import survey_runner as sr_mod
from addons.features.auto_survey.state_manager import SurveyState
from addons.features.auto_survey.rtkbase_config import RTKBaseConfig

acc.log_event = lambda *a, **k: None

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

def test_a():
    def make_server(include_blank):
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", 0))
        server.listen(1)
        port = server.getsockname()[1]
        def handler():
            conn, _ = server.accept()
            # Read request up to blank line before answering
            data = b""
            while b"\r\n\r\n" not in data:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
            if include_blank:
                conn.sendall(b"ICY 200 OK\r\n\r\n")
            else:
                conn.sendall(b"ICY 200 OK\r\n")
            start = time.time()
            while time.time() - start < 1.5:
                conn.sendall(b"BINARYDATA")
                time.sleep(0.1)
            conn.close()
            server.close()
        t = threading.Thread(target=handler, daemon=True)
        t.start()
        return port
    port1 = make_server(False)
    with tempfile.NamedTemporaryFile(delete=False) as f:
        out1 = f.name
    data1 = nc.capture_stream("127.0.0.1", port1, "MP1", "u", "p", out1, 3.0)
    assert data1["bytes"] >= 10, f"Expected >= 10 bytes, got {data1['bytes']}"
    with open(out1, "rb") as f:
        content1 = f.read()
    assert content1.startswith(b"BINARYDATA"), f"File should start with BINARYDATA, got {content1[:20]}"
    os.unlink(out1)
    port2 = make_server(True)
    with tempfile.NamedTemporaryFile(delete=False) as f:
        out2 = f.name
    data2 = nc.capture_stream("127.0.0.1", port2, "MP1", "u", "p", out2, 3.0)
    with open(out2, "rb") as f:
        content2 = f.read()
    assert content2.startswith(b"BINARYDATA"), f"File should start with BINARYDATA, got {content2[:20]}"
    os.unlink(out2)

test("A: ICY single CRLF", test_a)

def test_b():
    def make_auth_server(response):
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", 0))
        server.listen(1)
        port = server.getsockname()[1]
        def handler():
            conn, _ = server.accept()
            conn.recv(4096)
            conn.sendall(response)
            time.sleep(0.5)
            conn.close()
            server.close()
        t = threading.Thread(target=handler, daemon=True)
        t.start()
        return port
    port1 = make_auth_server(b"ERROR - Bad Password\r\n")
    with tempfile.NamedTemporaryFile(delete=False) as f:
        out1 = f.name
    try:
        nc.capture_stream("127.0.0.1", port1, "MP1", "u", "wrong", out1, 3.0)
        assert False, "Expected NtripError for bad password"
    except nc.NtripError as e:
        assert e.kind == "auth", f"Expected auth error, got {e.kind}"
    os.unlink(out1)
    port2 = make_auth_server(b"ICY 401 Unauthorized\r\n")
    with tempfile.NamedTemporaryFile(delete=False) as f:
        out2 = f.name
    try:
        nc.capture_stream("127.0.0.1", port2, "MP1", "u", "wrong", out2, 3.0)
        assert False, "Expected NtripError for 401"
    except nc.NtripError as e:
        assert e.kind == "auth", f"Expected auth error, got {e.kind}"
    os.unlink(out2)

test("B: v1 auth failure lines", test_b)

def test_c():
    decoder = nc._ChunkedDecoder()
    result = decoder.feed(b"4;ext=1\r\nWXYZ\r\n3\r\nabc\r\n0\r\n\r\n")
    assert result == b"WXYZabc", f"Expected WXYZabc, got {result}"

test("C: chunk extensions", test_c)

def test_d():
    gga1 = nc.make_gga(42.9999999999, 26.4, 100.0)
    match1 = re.search(r"\$GPGGA,[0-9.]+,(\d{2}\d{2}\.\d{7}),N,", gga1)
    assert match1, "Failed to parse GGA sentence"
    lat_field = match1.group(1)
    assert lat_field.startswith("4300.0000"), f"Expected 4300.0000, got {lat_field}"
    body = gga1[1:gga1.index("*")]
    xor = 0
    for ch in body:
        xor ^= ord(ch)
    expected_cksum = "%02X" % xor
    actual_cksum = gga1[gga1.index("*")+1:gga1.index("*")+3]
    assert expected_cksum == actual_cksum, f"Checksum mismatch: expected {expected_cksum}, got {actual_cksum}"
    gga2 = nc.make_gga(42.65, 26.43, 100.0)
    match2 = re.search(r"\$GPGGA,[0-9.]+,(\d{2}\d{2}\.\d{7}),N,", gga2)
    assert match2, "Failed to parse second GGA sentence"
    lat_field2 = match2.group(1)
    assert lat_field2.startswith("4239.0000"), f"Expected 4239.0000, got {lat_field2}"

test("D: make_gga carry", test_d)

def test_e():
    def make_settings():
        tmpdir = tempfile.mkdtemp()
        settings_path = os.path.join(tmpdir, "settings.conf")
        with open(settings_path, "w") as f:
            f.write("[main]\nposition='42.65236966 26.43258495 208.145'\n")
        return tmpdir, settings_path
    def make_rtkbase(settings_path):
        return RTKBaseConfig(settings_path)
    tmpdir1, settings1 = make_settings()
    rtkbase1 = make_rtkbase(settings1)
    events = []
    def recorder(category, event, details=None):
        events.append((category, event, details))
    result1 = ca.apply_position(rtkbase1, 42.65236966 + 1.8e-6, 26.43258495, 208.145,
                                source="cors",
                                restart=lambda: {"restarted": [], "failed": ["a"], "success": False},
                                audit=recorder)
    assert result1["ok"] == True, "Expected ok=True"
    assert result1["restart_ok"] == False, "Expected restart_ok=False"
    shutil.rmtree(tmpdir1)
    tmpdir2, settings2 = make_settings()
    rtkbase2 = make_rtkbase(settings2)
    result2 = ca.apply_position(rtkbase2, 42.65236966 + 1.8e-6, 26.43258495, 208.145,
                                source="cors",
                                restart=lambda: {"restarted": ["a"], "failed": [], "success": True},
                                audit=recorder)
    assert result2["restart_ok"] == True, "Expected restart_ok=True"
    shutil.rmtree(tmpdir2)
    tmpdir3, settings3 = make_settings()
    rtkbase3 = make_rtkbase(settings3)
    result3 = ca.apply_position(rtkbase3, 42.65236966 + 1.8e-6, 26.43258495, 208.145,
                                source="cors",
                                restart=lambda: None,
                                audit=recorder)
    assert result3["restart_ok"] == True, "Expected restart_ok=True"
    shutil.rmtree(tmpdir3)
    tmpdir4, settings4 = make_settings()
    rtkbase4 = make_rtkbase(settings4)
    result4 = ca.apply_position(rtkbase4, 42.65236966 + 1.8e-6, 26.43258495, 208.145,
                                source="cors",
                                restart=lambda: (_ for _ in ()).throw(RuntimeError("boom")),
                                audit=recorder)
    assert result4["restart_ok"] == False, "Expected restart_ok=False"
    shutil.rmtree(tmpdir4)

test("E: cors_apply restart result", test_e)

def test_f():
    assert sr_mod.cors_apply_blocked(SurveyState.RUNNING) == True, "RUNNING should be blocked"
    assert sr_mod.cors_apply_blocked(SurveyState.FINALIZING) == True, "FINALIZING should be blocked"
    assert sr_mod.cors_apply_blocked(SurveyState.PAUSED) == True, "PAUSED should be blocked"
    assert sr_mod.cors_apply_blocked(SurveyState.IDLE) == False, "IDLE should not be blocked"
    assert sr_mod.cors_apply_blocked(SurveyState.COMPLETED) == False, "COMPLETED should not be blocked"
    assert sr_mod.cors_apply_blocked(SurveyState.FAILED) == False, "FAILED should not be blocked"
    assert callable(sr_mod.build_cors_manager), "build_cors_manager should be callable"

test("F: runner guard", test_f)

def test_g():
    class FakeController:
        is_runner = False
        def recover_survey(self):
            return False
        def stop_survey(self):
            raise ValueError("boom")
        def get_status(self):
            return {"state": "idle"}
        def start_survey(self):
            return {"ok": True}
        def reset_survey(self):
            return {"ok": True}
    class BoomCors:
        def start(self, account_id, params=None):
            raise RuntimeError("leak-me-xyz")
        def cancel(self):
            pass
        def apply(self, job_id, confirmed, force=False):
            pass
    tmpdir = tempfile.mkdtemp()
    controller = FakeController()
    runner = sr_mod.SurveyRunner(lambda: controller, request_dir=tmpdir,
                                 cors_manager_factory=lambda c: BoomCors())
    runner.startup()
    result1 = runner.handle_request({"id": "1", "action": "cors_compute", "params": {"account_id": "abc"}})
    assert result1["ok"] == False, "Expected ok=False"
    assert result1["message"] == "internal error", f"Expected 'internal error', got {result1['message']}"
    assert result1["data"] is None, "Expected data=None"
    result2 = runner.handle_request({"id": "2", "action": "stop", "params": {}})
    assert "ValueError" in result2["message"], f"Expected ValueError in message, got {result2['message']}"
    shutil.rmtree(tmpdir)

test("G: runner error text", test_g)

def test_h():
    from addons.features.auto_survey import survey_requests
    recorded = []
    original_wait = survey_requests.wait_for_result
    def fake_wait(request_id, timeout, request_dir=None):
        recorded.append(timeout)
        return {"ok": True, "message": "x", "data": None}
    survey_requests.wait_for_result = fake_wait
    tmpdir = tempfile.mkdtemp()
    cc.request("cors_apply", {"job_id": "test"}, request_dir=tmpdir, start_service=lambda: True)
    assert recorded[-1] == 150.0, f"Expected 150.0, got {recorded[-1]}"
    cc.request("cors_compute", {"account_id": "test"}, request_dir=tmpdir, start_service=lambda: True)
    assert recorded[-1] == 30.0, f"Expected 30.0, got {recorded[-1]}"
    cc.request("cors_apply", {"job_id": "test"}, request_dir=tmpdir, start_service=lambda: True, timeout=7)
    assert recorded[-1] == 7, f"Expected 7, got {recorded[-1]}"
    survey_requests.wait_for_result = original_wait
    shutil.rmtree(tmpdir)

test("H: client timeouts", test_h)

def test_i():
    tmpdir = tempfile.mkdtemp()
    store_path = os.path.join(tmpdir, "accounts.json")
    work_root = os.path.join(tmpdir, "work")
    os.makedirs(work_root)
    leftover_dir = os.path.join(work_root, "oldjob")
    os.makedirs(leftover_dir)
    with open(os.path.join(leftover_dir, "file.bin"), "w") as f:
        f.write("data")
    with open(os.path.join(work_root, "stray.txt"), "w") as f:
        f.write("stray")
    account_id = acc.create_account({"name": "Net A", "host": "secret-host.example.org", "port": 2101, "mountpoint": "MP1", "username": "u1", "password": "p1"}, store_path)["id"]
    job_file = os.path.join(tmpdir, "job.json")
    cj.save_job({"job_id": "testjob12345", "status": "running", "stage": "compute", "info": "",
                 "account_id": account_id, "account_name": "Net A"}, job_file)
    settings_path = os.path.join(tmpdir, "settings.conf")
    with open(settings_path, "w") as f:
        f.write("[main]\nposition='42.65236966 26.43258495 208.145'\n")
    manager = cj.CorsJobManager(lambda: RTKBaseConfig(settings_path), accounts_path=store_path,
                                job_path=job_file, work_root=work_root,
                                compute_fn=lambda *a, **k: None, audit=lambda *a: None)
    with open(job_file) as f:
        job = json.load(f)
    assert job["status"] == "failed", f"Expected failed, got {job['status']}"
    assert job["stage"] == "interrupted", f"Expected interrupted, got {job['stage']}"
    remaining = os.listdir(work_root)
    assert len(remaining) == 0, f"Expected empty work_root, got {remaining}"
    shutil.rmtree(tmpdir)

test("I: job reconcile at construction", test_i)

def test_j():
    tmpdir = tempfile.mkdtemp()
    store_path = os.path.join(tmpdir, "accounts.json")
    work_root = os.path.join(tmpdir, "work")
    job_file = os.path.join(tmpdir, "job.json")
    settings_path = os.path.join(tmpdir, "settings.conf")
    with open(settings_path, "w") as f:
        f.write("[main]\nposition='42.65236966 26.43258495 208.145'\n")
    account_id = acc.create_account({"name": "Net A", "host": "secret-host.example.org", "port": 2101,
                                     "mountpoint": "MP1", "username": "u1", "password": "p1"}, store_path)["id"]

    def good_compute(account, work_dir, params, **k):
        lat, lon, h = 42.65236966 + 9e-8, 26.43258495, 208.15
        return {"ok": True, "stage": None, "kind": None, "reason": None, "account_id": account["id"],
                "account_name": account["name"], "frame": "ETRF2000@2005.0", "epoch": None, "mode": "vrs",
                "approx": [42.65, 26.43, 200.0], "base_xyz": [1.0, 2.0, 3.0],
                "summary": {"total": 200, "fixed": 150, "fix_ratio": 0.75, "first_fix_s": 20.0, "used": 120,
                            "lat": lat, "lon": lon, "h": h, "std_n_m": 0.004, "std_e_m": 0.004, "std_u_m": 0.008},
                "lat": lat, "lon": lon, "h": h, "rover_bytes": 1000, "base_bytes": 2000,
                "started_at": "2026-10-24T06:00:00+00:00", "finished_at": "2026-10-24T06:15:00+00:00"}

    def make_manager():
        return cj.CorsJobManager(lambda: RTKBaseConfig(settings_path), accounts_path=store_path,
                                 job_path=job_file, work_root=work_root, compute_fn=good_compute,
                                 audit=lambda *a: None)

    def run_job(manager):
        ok, job_id = manager.start(account_id)
        assert ok, f"start failed: {job_id}"
        deadline = time.time() + 10
        while time.time() < deadline:
            st = manager.status()
            if st["status"] != "running":
                break
            time.sleep(0.05)
        assert manager.status()["status"] == "done", "job should be done"
        return job_id

    # first job: normal apply, then a replay of the same job is refused
    manager = make_manager()
    job_id = run_job(manager)
    result1 = manager.apply(job_id, confirmed=True)
    assert result1["ok"] is True, f"first apply should work: {result1}"
    result2 = manager.apply(job_id, confirmed=True)
    assert result2["ok"] is False, "replay must be refused"
    assert "not finished successfully" in (result2.get("reason") or ""), f"reason: {result2.get('reason')}"

    # second job: saving the applied state fails, the apply is still reported as done
    # and cannot be repeated
    manager2 = make_manager()
    job_id2 = run_job(manager2)
    original_save = cj.save_job
    state = {"fail": False}

    def flaky_save(job, path=cj.DEFAULT_JOB_FILE):
        if state["fail"]:
            raise OSError("disk full")
        return original_save(job, path)

    cj.save_job = flaky_save
    try:
        state["fail"] = True
        # shift the proposal by a tiny amount so the jump guard accepts it
        result3 = manager2.apply(job_id2, confirmed=True)
        state["fail"] = False
    finally:
        cj.save_job = original_save
    assert result3["ok"] is True, f"apply should be reported ok although the save failed: {result3}"
    result4 = manager2.apply(job_id2, confirmed=True)
    assert result4["ok"] is False, "a second apply must be refused after a failed save"
    assert "not finished successfully" in (result4.get("reason") or ""), f"reason: {result4.get('reason')}"
    shutil.rmtree(tmpdir, ignore_errors=True)

test("J: apply replay protection", test_j)

def test_k():
    tmpdir = tempfile.mkdtemp()
    store_path = os.path.join(tmpdir, "accounts.json")
    settings_path = os.path.join(tmpdir, "settings.conf")
    with open(settings_path, "w") as f:
        f.write("[main]\nposition='42.65236966 26.43258495 208.145'\n")
    account_id = acc.create_account({"name": "Net A", "host": "secret-host.example.org", "port": 2101,
                                     "mountpoint": "MP1", "username": "u1", "password": "p1"}, store_path)["id"]
    events = []

    def recorder(category, event, details=None):
        events.append((category, event, details))

    def good_compute(account, work_dir, params, **k):
        lat, lon, h = 42.65236966 + 9e-8, 26.43258495, 208.15
        return {"ok": True, "stage": None, "kind": None, "reason": None, "account_id": account["id"],
                "account_name": account["name"], "frame": "ETRF2000@2005.0", "epoch": None, "mode": "vrs",
                "approx": None, "base_xyz": None,
                "summary": {"total": 10, "fixed": 10, "fix_ratio": 1.0, "first_fix_s": 1.0, "used": 10,
                            "lat": lat, "lon": lon, "h": h, "std_n_m": 0.001, "std_e_m": 0.001, "std_u_m": 0.002},
                "lat": lat, "lon": lon, "h": h, "rover_bytes": 1, "base_bytes": 1,
                "started_at": "x", "finished_at": "y"}

    manager = cj.CorsJobManager(lambda: RTKBaseConfig(settings_path), accounts_path=store_path,
                                job_path=os.path.join(tmpdir, "job.json"), work_root=os.path.join(tmpdir, "work"),
                                compute_fn=good_compute, audit=recorder)
    ok, job_id = manager.start(account_id)
    assert ok, f"start failed: {job_id}"
    deadline = time.time() + 10
    while time.time() < deadline and manager.status()["status"] == "running":
        time.sleep(0.05)
    res = manager.apply(job_id, confirmed=True)
    assert res["ok"] is True, f"apply failed: {res}"
    pos_events = [e for e in events if e[1] == "position_applied"]
    assert len(pos_events) == 1, f"Expected one position_applied event, got {len(pos_events)}"
    meta = pos_events[0][2].get("meta", {})
    assert meta.get("arp_corrected") is False, f"Expected arp_corrected=False in meta, got {meta}"
    assert "note" in meta, "Expected a note about the antenna reference point"
    shutil.rmtree(tmpdir, ignore_errors=True)

test("K: meta carries arp info", test_k)

def test_l():
    caster = cf.FakeCaster(user="u1", password="other", mountpoints=("MP1",))
    caster.start()
    receiver = cf.FakeReceiver()
    receiver.start()
    tmpdir = tempfile.mkdtemp()
    convbin, rnx2rtkp = cf.make_tools(tmpdir)
    pos_file = os.path.join(tmpdir, "pos.txt")
    cf.make_pos(pos_file, 150, 20)
    os.environ["FAKE_POS_SRC"] = pos_file
    try:
        account = cf.ACCOUNT(caster.port, mountpoint="MP1", password="wrong")
        start = time.time()
        result = cr.compute_position(account, os.path.join(tmpdir, "work"), {
            "duration_s": 30,
            "rover_host": "127.0.0.1",
            "rover_port": receiver.raw_port,
            "nmea_host": "127.0.0.1",
            "nmea_port": receiver.nmea_port,
            "convbin_path": convbin,
            "rnx2rtkp_path": rnx2rtkp,
            "min_used": 60
        })
        elapsed = time.time() - start
        assert elapsed < 8, f"Expected < 8s, got {elapsed}s"
        assert result["stage"] == "capture_base", f"Expected capture_base, got {result['stage']}"
        assert result["kind"] == "auth", f"Expected auth, got {result['kind']}"
    finally:
        caster.stop()
        receiver.stop()
        del os.environ["FAKE_POS_SRC"]
        shutil.rmtree(tmpdir)

test("L: capture abort", test_l)

def test_m():
    import subprocess
    try:
        result = subprocess.run(["which", "rnx2rtkp"], capture_output=True, text=True)
        if result.returncode == 0:
            print("SKIP: M")
            return
    except FileNotFoundError:
        pass
    tmpdir = tempfile.mkdtemp()
    empty_path = tempfile.mkdtemp()
    old_path = os.environ.get("PATH")
    os.environ["PATH"] = empty_path
    try:
        raw_port = cf.free_port()
        nmea_port = cf.free_port()
        start = time.time()
        result = cr.compute_position(
            cf.ACCOUNT(80, mountpoint="MP1"),
            os.path.join(tmpdir, "work"),
            {
                "duration_s": 30,
                "rover_host": "127.0.0.1",
                "rover_port": raw_port,
                "nmea_host": "127.0.0.1",
                "nmea_port": nmea_port,
                "convbin_path": None,
                "rnx2rtkp_path": None,
                "min_used": 60
            }
        )
        elapsed = time.time() - start
        assert elapsed < 3, f"Expected < 3s, got {elapsed}s"
        assert result["stage"] == "tools", f"Expected tools, got {result['stage']}"
        assert result["kind"] == "tool_missing", f"Expected tool_missing, got {result['kind']}"
    finally:
        if old_path:
            os.environ["PATH"] = old_path
        else:
            del os.environ["PATH"]
        shutil.rmtree(tmpdir, ignore_errors=True)
        shutil.rmtree(empty_path, ignore_errors=True)

test("M: tools first", test_m)

def test_n():
    caster = cf.FakeCaster()
    caster.start()
    receiver = cf.FakeReceiver()
    receiver.start()
    tmpdir = tempfile.mkdtemp()
    convbin, rnx2rtkp = cf.make_tools(tmpdir)
    pos_file = os.path.join(tmpdir, "pos.txt")
    cf.make_pos(pos_file, 150, 20)
    os.environ["FAKE_POS_SRC"] = pos_file
    stop_event = threading.Event()
    def progress(stage, info):
        if stage == "convert":
            stop_event.set()
    try:
        account = cf.ACCOUNT(caster.port)
        result = cr.compute_position(account, os.path.join(tmpdir, "work"), {
            "duration_s": 30,
            "rover_host": "127.0.0.1",
            "rover_port": receiver.raw_port,
            "nmea_host": "127.0.0.1",
            "nmea_port": receiver.nmea_port,
            "convbin_path": convbin,
            "rnx2rtkp_path": rnx2rtkp,
            "min_used": 60
        }, progress=progress, stop_event=stop_event)
        assert result["ok"] == False, "Expected ok=False"
        assert result["kind"] == "cancelled", f"Expected cancelled, got {result['kind']}"
        assert result["stage"] in ("convert", "solve"), f"Expected convert or solve, got {result['stage']}"
    finally:
        caster.stop()
        receiver.stop()
        del os.environ["FAKE_POS_SRC"]
        shutil.rmtree(tmpdir)

test("N: cancel between stages", test_n)

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(failed)
PYEOF
exit $?
