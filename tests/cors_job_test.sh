#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export GM_REPO_ROOT="$REPO"
python3 << 'PYEOF'
import os, sys, json, time, threading, tempfile, stat
from types import SimpleNamespace

repo = os.environ["GM_REPO_ROOT"]
sys.path.insert(0, repo)
sys.path.insert(0, os.path.join(repo, "tests"))

import cors_fakes as cf
cf.install_stubs()

from addons.features.cors_position import cors_job as cj
from addons.features.cors_position import cors_accounts as ca
from addons.features.auto_survey.rtkbase_config import RTKBaseConfig

# never write the real audit log from the account store during tests
ca.log_event = lambda *a, **k: None

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

START = (42.65236966, 26.43258495, 208.145)

def make_env(tmp, fmt="ubx", frame="ETRF2000@2005.0", epoch=None, enabled=True, position=True):
    settings_path = os.path.join(tmp, "settings.conf")
    lines = ["[general]", "user=peshovp", "", "[main]"]
    if position:
        lines.append(f"position='{START[0]} {START[1]} {START[2]}'")
    lines.append(f"receiver_format='{fmt}'")
    with open(settings_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    accounts_path = os.path.join(tmp, "accounts.json")
    job_path = os.path.join(tmp, "job.json")
    work_root = os.path.join(tmp, "work")
    os.makedirs(work_root, exist_ok=True)
    acct = ca.create_account({
        "name": "Net A", "host": "secret-host.example.org",
        "port": 2101, "mountpoint": "SECRETMP",
        "username": "secret-user", "password": "secret-pass",
        "frame": frame, "epoch": epoch, "enabled": enabled
    }, accounts_path)
    return SimpleNamespace(
        settings_path=settings_path, accounts_path=accounts_path,
        job_path=job_path, work_root=work_root,
        account_id=acct["id"],
        rtkbase_factory=lambda: RTKBaseConfig(settings_path),
        events=[], calls=[]
    )

def good_result(lat=START[0] + 9e-8, lon=START[1], h=START[2] + 0.005, frame="ETRF2000@2005.0"):
    return {
        "ok": True, "stage": None, "kind": None, "reason": None,
        "account_id": "x", "account_name": "Net A",
        "frame": frame, "epoch": None, "mode": "vrs",
        "approx": [42.65, 26.43, 200.0], "base_xyz": [1.0, 2.0, 3.0],
        "summary": {"total": 200, "fixed": 150, "fix_ratio": 0.75,
                    "first_fix_s": 20.0, "used": 120,
                    "lat": lat, "lon": lon, "h": h,
                    "std_n_m": 0.004, "std_e_m": 0.004, "std_u_m": 0.008},
        "lat": lat, "lon": lon, "h": h,
        "rover_bytes": 1000, "base_bytes": 2000,
        "started_at": "2026-10-24T06:00:00+00:00",
        "finished_at": "2026-10-24T06:15:00+00:00"
    }

def make_manager(env, compute_fn, **kw):
    return cj.CorsJobManager(
        env.rtkbase_factory,
        accounts_path=env.accounts_path,
        job_path=env.job_path,
        work_root=env.work_root,
        compute_fn=compute_fn,
        restart=lambda: env.calls.append("restart"),
        announce=lambda: env.calls.append("announce"),
        audit=lambda c, e, d=None: env.events.append((c, e, d)),
        **kw
    )

def wait_not_running(mgr, timeout=10):
    deadline = time.time() + timeout
    while time.time() < deadline:
        s = mgr.status()
        if s.get("status") != "running":
            return s
        time.sleep(0.05)
    return mgr.status()

def test_a_start_and_done():
    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp)
        params_received = {}
        def compute(account, work_dir, params, progress=None, stop_event=None):
            params_received.update(params)
            if progress:
                progress("capture", "capturing")
            return good_result()
        mgr = make_manager(env, compute)
        ok, job_id = mgr.start(env.account_id)
        assert ok and len(job_id) == 12 and all(c in "0123456789abcdef" for c in job_id)
        s = wait_not_running(mgr)
        assert s["status"] == "done"
        assert s["result"]["lat"] == START[0] + 9e-8
        assert s["comparison"]["within_threshold"] is True
        mode = os.stat(env.job_path).st_mode & 0o777
        assert mode == 0o600
        with open(env.job_path) as f:
            text = f.read()
        for secret in ["secret-host", "SECRETMP", "secret-user", "secret-pass"]:
            assert secret not in text
        assert params_received.get("rover_suffix") == ".ubx"

def test_b_compare_positions():
    dlat = 0.01 / 111132.92
    proposal = (START[0] + dlat, START[1], START[2] + 0.02)
    c = cj.compare_positions(proposal, START)
    assert abs(c["d_north_m"] - 0.01) < 1e-4
    assert abs(c["d_east_m"]) < 1e-6
    assert abs(c["d_up_m"] - 0.02) < 1e-6
    assert abs(c["horizontal_m"] - 0.01) < 1e-4
    assert abs(c["vertical_m"] - 0.02) < 1e-4
    assert c["within_threshold"] is True
    assert c["hint"] == "consistent with the current position"
    big = (START[0] + 0.5 / 111132.92, START[1], START[2])
    c2 = cj.compare_positions(big, START)
    assert c2["within_threshold"] is False
    assert c2["hint"].startswith("small difference")
    huge = (START[0] + 5.0 / 111132.92, START[1], START[2])
    c3 = cj.compare_positions(huge, START)
    assert c3["hint"].startswith("large difference")
    vert = (START[0] + 0.01 / 111132.92, START[1], START[2] + 0.2)
    c4 = cj.compare_positions(vert, START)
    assert c4["within_threshold"] is False
    assert cj.compare_positions(START, None) is None

def test_c_start_refusals():
    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp)
        mgr = make_manager(env, lambda *a, **k: None)
        ok, msg = mgr.start("doesnotexist")
        assert not ok and msg == "unknown account"
    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp, enabled=False)
        mgr = make_manager(env, lambda *a, **k: None)
        ok, msg = mgr.start(env.account_id)
        assert not ok and msg == "account is disabled"
    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp)
        ev = threading.Event()
        def blocked_compute(*a, **k):
            ev.wait(10)
            return good_result()
        mgr = make_manager(env, blocked_compute)
        mgr.start(env.account_id)
        time.sleep(0.1)
        ok, msg = mgr.start(env.account_id)
        assert not ok and msg == "a CORS computation is already running"
        ev.set()
        wait_not_running(mgr)

def test_d_failed_and_cancelled():
    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp)
        def fail_compute(*a, **k):
            return {"ok": False, "stage": "capture_base", "kind": "auth",
                    "reason": "authentication failed", "lat": None, "lon": None,
                    "h": None, "summary": None, "account_id": "x",
                    "account_name": "Net A", "frame": "ETRF2000@2005.0",
                    "epoch": None, "mode": "vrs", "approx": None,
                    "base_xyz": None, "rover_bytes": 0, "base_bytes": 0,
                    "started_at": None, "finished_at": None}
        mgr = make_manager(env, fail_compute)
        mgr.start(env.account_id)
        s = wait_not_running(mgr)
        assert s["status"] == "failed"
        assert s["result"]["kind"] == "auth"
        assert s["comparison"] is None
    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp)
        def cancel_compute(*a, **k):
            return {"ok": False, "stage": None, "kind": "cancelled",
                    "reason": None, "lat": None, "lon": None, "h": None,
                    "summary": None, "account_id": "x", "account_name": "Net A",
                    "frame": "ETRF2000@2005.0", "epoch": None, "mode": "vrs",
                    "approx": None, "base_xyz": None, "rover_bytes": 0,
                    "base_bytes": 0, "started_at": None, "finished_at": None}
        mgr = make_manager(env, cancel_compute)
        mgr.start(env.account_id)
        s = wait_not_running(mgr)
        assert s["status"] == "cancelled"

def test_e_cancel():
    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp)
        def wait_compute(*a, stop_event=None, **k):
            stop_event.wait(10)
            return {"ok": False, "stage": None, "kind": "cancelled",
                    "reason": None, "lat": None, "lon": None, "h": None,
                    "summary": None, "account_id": "x", "account_name": "Net A",
                    "frame": "ETRF2000@2005.0", "epoch": None, "mode": "vrs",
                    "approx": None, "base_xyz": None, "rover_bytes": 0,
                    "base_bytes": 0, "started_at": None, "finished_at": None}
        mgr = make_manager(env, wait_compute)
        mgr.start(env.account_id)
        time.sleep(0.1)
        assert mgr.cancel() is True
        s = wait_not_running(mgr, timeout=5)
        assert s["status"] == "cancelled"
        assert mgr.cancel() is False

def test_f_exception():
    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp)
        def raise_compute(*a, **k):
            raise RuntimeError("leak-me")
        mgr = make_manager(env, raise_compute)
        mgr.start(env.account_id)
        s = wait_not_running(mgr)
        assert s["status"] == "failed"
        assert s["stage"] == "internal"
        assert s["info"] == "internal error"
        with open(env.job_path) as f:
            assert "leak-me" not in f.read()

def test_g_interrupted():
    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp)
        cj.save_job({
            "job_id": "abc123abc123", "status": "running",
            "stage": "capture", "info": "", "account_id": env.account_id,
            "account_name": "Net A", "frame": "ETRF2000@2005.0",
            "epoch": None, "mode": "vrs",
            "started_at": "2026-10-24T06:00:00+00:00",
            "finished_at": None, "result": None,
            "comparison": None, "applied_at": None,
            "apply_result": None, "last_apply_error": None
        }, env.job_path)
        mgr = make_manager(env, lambda *a, **k: None)
        s = mgr.status()
        assert s["status"] == "failed"
        assert s["stage"] == "interrupted"
        with open(env.job_path) as f:
            data = json.load(f)
        assert data["status"] == "failed"
        assert any(e[1] == "compute_interrupted" for e in env.events)

def test_h_apply_flow():
    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp)
        def compute(*a, **k):
            return good_result()
        mgr = make_manager(env, compute)
        ok, job_id = mgr.start(env.account_id)
        s = wait_not_running(mgr)
        assert s["status"] == "done"
        res = mgr.apply(job_id, confirmed=True)
        assert res["ok"] is True
        with open(env.settings_path) as f:
            text = f.read()
        assert f"{START[0] + 9e-8}" in text
        s2 = mgr.status()
        assert s2["status"] == "applied"
        assert s2["applied_at"] is not None
        assert env.calls == ["announce", "restart"]
        assert any(e[1] == "position_applied" for e in env.events)
        res2 = mgr.apply(job_id, confirmed=True)
        assert res2["ok"] is False
        assert res2["reason"] == "computation not finished successfully"
    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp)
        def compute2(*a, **k):
            return good_result()
        mgr2 = make_manager(env, compute2)
        ok, jid = mgr2.start(env.account_id)
        wait_not_running(mgr2)
        for confirmed in [False, "yes", 1]:
            res = mgr2.apply(jid, confirmed=confirmed)
            assert res["ok"] is False
            assert res["reason"] == "confirmation required"
        with open(env.settings_path) as f:
            assert f"{START[0] + 9e-8}" not in f.read()

def test_i_apply_refusals():
    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp)
        def compute(*a, **k):
            return good_result()
        mgr = make_manager(env, compute)
        ok, jid = mgr.start(env.account_id)
        wait_not_running(mgr)
        res = mgr.apply("wrongid", confirmed=True)
        assert res["reason"] == "no such computation"
    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp, frame="ITRF2020@epoch", epoch=2015.0)
        def compute2(*a, **k):
            return good_result(frame="ITRF2020@epoch")
        mgr2 = make_manager(env, compute2)
        ok, jid2 = mgr2.start(env.account_id)
        wait_not_running(mgr2)
        res2 = mgr2.apply(jid2, confirmed=True)
        assert "BGS2005" in res2["reason"]
    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp)
        def compute3(*a, **k):
            return good_result()
        mgr3 = make_manager(env, compute3, survey_running=lambda: True)
        ok, jid3 = mgr3.start(env.account_id)
        wait_not_running(mgr3)
        res3 = mgr3.apply(jid3, confirmed=True)
        assert res3["reason"] == "a survey is running"
    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp)
        def compute4(*a, **k):
            return good_result(lat=START[0] + 0.001)
        mgr4 = make_manager(env, compute4)
        ok, jid4 = mgr4.start(env.account_id)
        wait_not_running(mgr4)
        res4 = mgr4.apply(jid4, confirmed=True)
        assert res4["reason"] == "change too large"
        s4 = mgr4.status()
        assert s4["status"] == "done"
        assert s4["last_apply_error"] == "change too large"
        with open(env.settings_path) as f:
            assert f"{START[0] + 0.001}" not in f.read()
        res4b = mgr4.apply(jid4, confirmed=True, force=True)
        assert res4b["ok"] is True

def test_j_audit_no_secrets():
    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp)
        def compute(*a, **k):
            return good_result()
        mgr = make_manager(env, compute)
        ok, jid = mgr.start(env.account_id)
        wait_not_running(mgr)
        mgr.apply(jid, confirmed=True)
        text = json.dumps(env.events)
        for secret in ["secret-host", "SECRETMP", "secret-user", "secret-pass"]:
            assert secret not in text
        names = [e[1] for e in env.events]
        assert "compute_started" in names
        assert "compute_finished" in names
        assert "position_applied" in names

def test_k_receiver_format():
    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp, fmt="unicore")
        params_received = {}
        def compute(account, work_dir, params, **k):
            if params:
                params_received.update(params)
            return good_result()
        mgr = make_manager(env, compute)
        mgr.start(env.account_id)
        wait_not_running(mgr)
        assert params_received.get("rover_suffix") == ".unicore"
    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp)
        params_received2 = {}
        def broken_factory():
            raise RuntimeError("no receiver")
        def compute2(account, work_dir, params, **k):
            if params:
                params_received2.update(params)
            return good_result()
        mgr2 = cj.CorsJobManager(
            broken_factory,
            accounts_path=env.accounts_path,
            job_path=env.job_path,
            work_root=env.work_root,
            compute_fn=compute2,
            restart=lambda: None,
            announce=lambda: None,
            audit=lambda *a: None
        )
        mgr2.start(env.account_id)
        wait_not_running(mgr2)
        assert params_received2.get("rover_suffix") == ".ubx"

def test_l_save_load():
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "sub", "dir", "job.json")
        data = {"key": "value", "num": 42}
        cj.save_job(data, path)
        assert os.path.exists(path)
        assert os.stat(os.path.dirname(path)).st_mode & 0o777 == 0o700
        assert os.stat(path).st_mode & 0o777 == 0o600
        loaded = cj.load_job(path)
        assert loaded == data
        with open(path, "w") as f:
            f.write("not json")
        assert cj.load_job(path) is None
        assert cj.load_job(os.path.join(tmp, "missing.json")) is None

test("A start and done", test_a_start_and_done)
test("B compare_positions", test_b_compare_positions)
test("C start refusals", test_c_start_refusals)
test("D failed and cancelled", test_d_failed_and_cancelled)
test("E cancel", test_e_cancel)
test("F exception", test_f_exception)
test("G interrupted", test_g_interrupted)
test("H apply flow", test_h_apply_flow)
test("I apply refusals", test_i_apply_refusals)
test("J audit no secrets", test_j_audit_no_secrets)
test("K receiver format", test_k_receiver_format)
test("L save/load job", test_l_save_load)

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(failed)
PYEOF
exit $?
