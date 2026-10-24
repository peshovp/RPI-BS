#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export GM_REPO_ROOT="$REPO"
python3 << 'PYEOF'
import os, sys, json, time, tempfile, threading
from types import SimpleNamespace

repo = os.environ["GM_REPO_ROOT"]
sys.path.insert(0, repo)
sys.path.insert(0, os.path.join(repo, "tests"))

import cors_fakes as cf
cf.install_stubs()

from addons.features.cors_position import cors_job as cj
from addons.features.cors_position import cors_accounts as ca
from addons.features.cors_position import cors_frame as cfr
from addons.features.auto_survey.rtkbase_config import RTKBaseConfig

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
RAW = (START[0] + 4.44e-6, START[1] + 8.9e-6, START[2] - 0.006)
CONVERTED = (START[0] + 9e-8, START[1] + 1e-8, START[2] + 0.001)

def make_env(tmp, frame="ITRF2020@epoch", epoch=2020.0):
    settings = os.path.join(tmp, "settings.conf")
    with open(settings, "w") as f:
        f.write("[main]\nposition='42.65236966 26.43258495 208.145'\n")
    accounts_path = os.path.join(tmp, "accounts.json")
    job_path = os.path.join(tmp, "job.json")
    work_root = os.path.join(tmp, "work")
    os.makedirs(work_root, exist_ok=True)
    account_id = ca.create_account({
        "name": "Net A", "host": "secret-host.example.org", "port": 2101,
        "mountpoint": "SECRETMP", "username": "secret-user",
        "password": "secret-pass", "frame": frame, "epoch": epoch
    }, accounts_path)["id"]
    return SimpleNamespace(settings=settings, accounts_path=accounts_path,
                           job_path=job_path, work_root=work_root,
                           account_id=account_id, events=[], calls=[])

def good_compute(account, work_dir, params, **k):
    return {
        "ok": True, "stage": None, "kind": None, "reason": None,
        "account_id": account["id"], "account_name": account["name"],
        "frame": account["frame"], "epoch": account["epoch"],
        "mode": "vrs", "approx": [42.65, 26.43, 200.0],
        "base_xyz": [1.0, 2.0, 3.0],
        "summary": {"total": 200, "fixed": 150, "fix_ratio": 0.75,
                    "first_fix_s": 20.0, "used": 120,
                    "lat": RAW[0], "lon": RAW[1], "h": RAW[2],
                    "std_n_m": 0.004, "std_e_m": 0.004, "std_u_m": 0.008},
        "lat": RAW[0], "lon": RAW[1], "h": RAW[2],
        "rover_bytes": 1000, "base_bytes": 2000,
        "started_at": "x", "finished_at": "y"
    }

convert_calls = []

def fake_convert(lat, lon, h, frame, epoch):
    convert_calls.append((lat, lon, h, frame, epoch))
    return {
        "lat": CONVERTED[0], "lon": CONVERTED[1], "h": CONVERTED[2],
        "frame_in": frame, "epoch_in": epoch,
        "method": "itrf2020_to_bgs2005", "shift_m": 1.07,
        "shift_n_m": -0.6, "shift_e_m": -0.89, "shift_u_m": 0.007,
        "provisional": True, "provisional_reason": "proxy velocity"
    }

def make_manager(env, compute_fn, convert_fn=None, **kw):
    return cj.CorsJobManager(
        lambda: RTKBaseConfig(env.settings),
        accounts_path=env.accounts_path, job_path=env.job_path,
        work_root=env.work_root, compute_fn=compute_fn,
        convert_fn=convert_fn,
        restart=lambda: env.calls.append("restart"),
        audit=lambda c, e, d=None: env.events.append((c, e, d)),
        **kw
    )

def run_job(mgr, env):
    ok, job_id = mgr.start(env.account_id)
    assert ok, "start failed"
    for _ in range(100):
        time.sleep(0.1)
        status = mgr.status()
        if status.get("status") != "running":
            return job_id, status
    raise TimeoutError("job did not finish")

def test_a():
    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp)
        convert_calls.clear()
        mgr = make_manager(env, good_compute, fake_convert)
        job_id, status = run_job(mgr, env)
        assert status["status"] == "done"
        assert status["converted"]["lat"] == CONVERTED[0]
        assert status["converted"]["lon"] == CONVERTED[1]
        assert status["converted"]["h"] == CONVERTED[2]
        assert status["converted"]["method"] == "itrf2020_to_bgs2005"
        assert status["converted"]["provisional"] is True
        assert len(convert_calls) == 1
        assert convert_calls[0][0] == RAW[0]
        assert convert_calls[0][1] == RAW[1]
        assert convert_calls[0][2] == RAW[2]
        assert convert_calls[0][3] == "ITRF2020@epoch"
        assert convert_calls[0][4] == 2020.0
        assert status["comparison"]["within_threshold"] is True
        assert status["comparison"]["horizontal_m"] < 0.03
        assert status["conversion_error"] is None
        with open(env.job_path) as f:
            text = f.read()
        for secret in ["secret-host", "SECRETMP", "secret-user", "secret-pass"]:
            assert secret not in text, f"secret {secret} leaked"

def test_b():
    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp)
        mgr = make_manager(env, good_compute, fake_convert)
        job_id, status = run_job(mgr, env)
        res = mgr.apply(job_id, confirmed=True)
        assert res["ok"] is True
        with open(env.settings) as f:
            text = f.read()
        expected = f"{CONVERTED[0]:.8f} {CONVERTED[1]:.8f} {CONVERTED[2]:.3f}"
        assert expected in text
        raw_fmt = f"{RAW[0]:.8f} {RAW[1]:.8f} {RAW[2]:.3f}"
        assert raw_fmt not in text
        status = mgr.status()
        assert status["status"] == "applied"
        applied_event = [e for e in env.events if e[1] == "position_applied"][0]
        meta = applied_event[2]["meta"]
        assert meta["frame"] == "ITRF2020@epoch"
        assert meta["frame_epoch"] == 2020.0
        assert meta["conversion"] == "itrf2020_to_bgs2005"
        assert meta["frame_shift_m"] == 1.07
        assert meta["provisional"] is True
        assert meta["arp_corrected"] is False

def test_c():
    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp)
        def bad_convert(lat, lon, h, frame, epoch):
            raise cfr.FrameError("the coordinate epoch of the account is required")
        mgr = make_manager(env, good_compute, bad_convert)
        job_id, status = run_job(mgr, env)
        assert status["status"] == "done"
        assert status["converted"] is None
        assert status["conversion_error"] == "the coordinate epoch of the account is required"
        assert status["comparison"] is not None
        assert status["comparison"]["horizontal_m"] > 0.5
        res = mgr.apply(job_id, confirmed=True)
        assert res["ok"] is False
        assert res["reason"] == "no BGS2005 position could be derived: the coordinate epoch of the account is required"
        with open(env.settings) as f:
            text = f.read()
        assert "42.65236966 26.43258495 208.145" in text

    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp)
        def leak_convert(lat, lon, h, frame, epoch):
            raise RuntimeError("leak-me")
        mgr = make_manager(env, good_compute, leak_convert)
        job_id, status = run_job(mgr, env)
        assert status["conversion_error"] == "the frame conversion failed"
        with open(env.job_path) as f:
            text = f.read()
        assert "leak-me" not in text

def test_d():
    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp, frame="ETRF2000@2005.0", epoch=None)
        mgr = make_manager(env, good_compute)
        job_id, status = run_job(mgr, env)
        assert status["converted"]["lat"] == RAW[0]
        assert status["converted"]["lon"] == RAW[1]
        assert status["converted"]["h"] == RAW[2]
        assert status["converted"]["method"] == "none"
        assert status["comparison"]["within_threshold"] is False
        assert status["comparison"]["horizontal_m"] > 0.5
        res = mgr.apply(job_id, confirmed=True)
        assert res["ok"] is True
        with open(env.settings) as f:
            text = f.read()
        expected = f"{RAW[0]:.8f} {RAW[1]:.8f} {RAW[2]:.3f}"
        assert expected in text

def test_e():
    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp)
        convert_calls.clear()
        def bad_compute(account, work_dir, params, **k):
            return {
                "ok": False, "stage": "capture_base", "kind": "auth",
                "reason": "authentication failed", "account_id": account["id"],
                "account_name": account["name"], "frame": account["frame"],
                "epoch": account["epoch"], "mode": "vrs", "approx": None,
                "base_xyz": None, "summary": None, "lat": None, "lon": None,
                "h": None, "rover_bytes": 0, "base_bytes": 0,
                "started_at": "x", "finished_at": "y"
            }
        mgr = make_manager(env, bad_compute, fake_convert)
        job_id, status = run_job(mgr, env)
        assert status["status"] == "failed"
        assert status["converted"] is None
        assert status["conversion_error"] is None
        assert len(convert_calls) == 0

def test_f():
    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp)
        def bad_convert(lat, lon, h, frame, epoch):
            raise cfr.FrameError("the coordinate epoch of the account is required")
        mgr = make_manager(env, good_compute, bad_convert,
                           survey_running=lambda: True)
        job_id, status = run_job(mgr, env)
        res = mgr.apply(job_id, confirmed=True)
        assert res["reason"] == "no BGS2005 position could be derived: the coordinate epoch of the account is required"

    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp)
        mgr = make_manager(env, good_compute, fake_convert,
                           survey_running=lambda: True)
        job_id, status = run_job(mgr, env)
        res = mgr.apply(job_id, confirmed=True)
        assert res["reason"] == "a survey is running"

    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp)
        mgr = make_manager(env, good_compute, fake_convert)
        job_id, status = run_job(mgr, env)
        res = mgr.apply(job_id, confirmed=False)
        assert res["reason"] == "confirmation required"

def test_g():
    with tempfile.TemporaryDirectory() as tmp:
        env = make_env(tmp)
        convert_calls.clear()
        def poor_compute(account, work_dir, params, **k):
            return {
                "ok": False, "stage": "evaluate", "kind": "poor_solution",
                "reason": "fix ratio too low", "account_id": account["id"],
                "account_name": account["name"], "frame": account["frame"],
                "epoch": account["epoch"], "mode": "vrs", "approx": None,
                "base_xyz": None,
                "summary": {"total": 200, "fixed": 50, "fix_ratio": 0.25,
                            "first_fix_s": 20.0, "used": 40,
                            "lat": RAW[0], "lon": RAW[1], "h": RAW[2],
                            "std_n_m": 0.004, "std_e_m": 0.004, "std_u_m": 0.008},
                "lat": RAW[0], "lon": RAW[1], "h": RAW[2],
                "rover_bytes": 1000, "base_bytes": 2000,
                "started_at": "x", "finished_at": "y"
            }
        mgr = make_manager(env, poor_compute, fake_convert)
        job_id, status = run_job(mgr, env)
        assert status["status"] == "failed"
        assert status["converted"] is not None
        assert len(convert_calls) == 1
        res = mgr.apply(job_id, confirmed=True)
        assert res["ok"] is False
        assert res["reason"] == "computation not finished successfully"

test("A conversion stored and used for comparison", test_a)
test("B apply writes converted position", test_b)
test("C conversion failure blocks apply", test_c)
test("D default conversion for BGS2005 frame", test_d)
test("E failed computation has no conversion", test_e)
test("F refusal order", test_f)
test("G poor solution carries converted view", test_g)

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(failed)
PYEOF
exit $?
