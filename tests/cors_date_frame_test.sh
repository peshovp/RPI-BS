#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export GM_REPO_ROOT="$REPO"
python3 << 'PYEOF'
import os, sys, json, time, tempfile, shutil
repo = os.environ["GM_REPO_ROOT"]
sys.path.insert(0, repo)
sys.path.insert(0, os.path.join(repo, "tests"))
import cors_fakes as cf
cf.install_stubs()
from addons.features.cors_position import cors_accounts as ca, cors_frame as cfr, cors_job as cj
from addons.features.auto_survey.rtkbase_config import RTKBaseConfig
ca.log_event = lambda *a, **k: None

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
        import traceback
        print(f"FAIL: {name}: {e!r} at line {traceback.extract_tb(e.__traceback__)[-1].lineno}")

def test_a_account_store():
    assert "ITRF2020@date" in ca.FRAMES, "ITRF2020@date not in FRAMES"
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "accounts.json")
        acc = {"name": "N", "host": "caster.example.org", "port": 2101,
               "mountpoint": "AUTO", "username": "u", "password": "p",
               "frame": "ITRF2020@date"}
        r = ca.create_account(acc, path)
        assert r["frame"] == "ITRF2020@date", f"frame {r['frame']}"
        assert r["epoch"] is None, f"epoch {r['epoch']}"
        try:
            ca.create_account({**acc, "epoch": 2020.0}, path)
            assert False, "should have raised"
        except ca.CorsAccountsError:
            pass
        ca.update_account(r["id"], {"frame": "ITRF2020@date"}, path)
        updated = ca.get_account(r["id"], path)
        assert updated["frame"] == "ITRF2020@date"
        assert updated["epoch"] is None

def test_b_frame_conversion():
    calls = []
    def fake_itrf(lat, lon, h, epoch):
        calls.append((lat, lon, h, epoch))
        return {"lat_dd": lat - 5e-6, "lon_dd": lon - 1e-5, "height_m": h + 0.002}
    r = cfr.to_bgs2005(42.65, 26.43, 200.0, "ITRF2020@date", 2026.80, itrf_fn=fake_itrf)
    assert calls[0][3] == 2026.80, f"epoch {calls[0][3]}"
    assert r["method"] == "itrf2020_to_bgs2005"
    assert r["frame_in"] == "ITRF2020@date"
    assert r["epoch_in"] == 2026.80
    assert 0.9 < r["shift_m"] < 1.1, f"shift {r['shift_m']}"
    for ep in [None, 1800.0, True, "x"]:
        try:
            cfr.to_bgs2005(42.65, 26.43, 200.0, "ITRF2020@date", ep, itrf_fn=fake_itrf)
            assert False, f"should have raised for {ep}"
        except cfr.FrameError as e:
            assert "observation epoch is required" in str(e)

def test_c_decimal_year():
    assert abs(cj._decimal_year("2026-01-01T00:00:00+00:00") - 2026.0) < 1e-9
    expected = 2026 + 182.5 / 365
    assert abs(cj._decimal_year("2026-07-02T12:00:00+00:00") - expected) < 1e-6
    expected_leap = 2024 + 365.5 / 366
    assert abs(cj._decimal_year("2024-12-31T12:00:00+00:00") - expected_leap) < 1e-6
    naive = cj._decimal_year("2026-10-24T14:30:51")
    assert 2026.80 < naive < 2026.82, f"naive {naive}"
    assert cj._decimal_year(None) is None
    assert cj._decimal_year("garbage") is None

def test_d_job_passes_epoch():
    with tempfile.TemporaryDirectory() as d:
        accounts_path = os.path.join(d, "accounts.json")
        job_path = os.path.join(d, "jobs.json")
        work_root = os.path.join(d, "work")
        settings = os.path.join(d, "settings.conf")
        with open(settings, "w") as f:
            f.write("[main]\nposition='42.65236966 26.43258495 208.145'\n")
        acc = {"name": "N", "host": "caster.example.org", "port": 2101,
               "mountpoint": "AUTO", "username": "u", "password": "p",
               "frame": "ITRF2020@date"}
        created = ca.create_account(acc, accounts_path)
        convert_calls = []
        def compute(account, work_dir, params, **k):
            return {"ok": True, "stage": None, "kind": None, "reason": None,
                    "account_id": account["id"], "account_name": account["name"],
                    "frame": "ITRF2020@date", "epoch": None, "mode": "vrs",
                    "approx": [42.65, 26.43, 200.0], "base_xyz": [1.0, 2.0, 3.0],
                    "summary": {"total": 10, "fixed": 10, "fix_ratio": 1.0,
                                "first_fix_s": 1.0, "used": 10,
                                "lat": 42.65236966, "lon": 26.43258495, "h": 208.145,
                                "std_n_m": 0.001, "std_e_m": 0.001, "std_u_m": 0.002},
                    "lat": 42.65236966, "lon": 26.43258495, "h": 208.145,
                    "rover_bytes": 1, "base_bytes": 1,
                    "started_at": "2026-10-24T14:15:43+00:00",
                    "finished_at": "2026-10-24T14:30:51+00:00"}
        def convert(lat, lon, h, frame, epoch):
            convert_calls.append((lat, lon, h, frame, epoch))
            return {"lat": lat + 9e-8, "lon": lon, "h": h + 0.001,
                    "method": "itrf2020_to_bgs2005", "shift_m": 0.9,
                    "shift_n_m": -0.5, "shift_e_m": -0.7, "shift_u_m": 0.0,
                    "provisional": True, "provisional_reason": "proxy"}
        recorder = []
        def audit(category, event, details=None):
            recorder.append({"event": event, "meta": (details or {}).get("meta")})
        manager = cj.CorsJobManager(lambda: RTKBaseConfig(settings),
                                    accounts_path=accounts_path, job_path=job_path,
                                    work_root=work_root, compute_fn=compute,
                                    convert_fn=convert, audit=audit)
        ok, job_id = manager.start(created["id"])
        for _ in range(100):
            status = manager.status()
            if status["status"] != "running":
                break
            time.sleep(0.1)
        assert len(convert_calls) == 1, f"convert called {len(convert_calls)} times"
        assert convert_calls[0][3] == "ITRF2020@date"
        expected_epoch = cj._decimal_year("2026-10-24T14:30:51+00:00")
        assert 2026.80 < expected_epoch < 2026.82, f"expected {expected_epoch}"
        assert abs(convert_calls[0][4] - expected_epoch) < 1e-6, f"epoch {convert_calls[0][4]}"
        assert abs(status["conversion_epoch"] - expected_epoch) < 1e-6
        result = manager.apply(job_id, confirmed=True)
        assert result["ok"] is True
        events = [e for e in recorder if e["event"] == "position_applied"]
        assert len(events) == 1
        assert abs(events[0]["meta"]["frame_epoch"] - expected_epoch) < 1e-6

def test_e_fixed_epoch_unchanged():
    with tempfile.TemporaryDirectory() as d:
        accounts_path = os.path.join(d, "accounts.json")
        job_path = os.path.join(d, "jobs.json")
        work_root = os.path.join(d, "work")
        settings = os.path.join(d, "settings.conf")
        with open(settings, "w") as f:
            f.write("[main]\nposition='42.65236966 26.43258495 208.145'\n")
        acc1 = {"name": "N1", "host": "caster.example.org", "port": 2101,
                "mountpoint": "AUTO", "username": "u", "password": "p",
                "frame": "ITRF2020@epoch", "epoch": 2020.0}
        created1 = ca.create_account(acc1, accounts_path)
        convert_calls = []
        def compute(account, work_dir, params, **k):
            return {"ok": True, "stage": None, "kind": None, "reason": None,
                    "account_id": account["id"], "account_name": account["name"],
                    "frame": account["frame"], "epoch": account.get("epoch"),
                    "mode": "vrs", "approx": [42.65, 26.43, 200.0],
                    "base_xyz": [1.0, 2.0, 3.0],
                    "summary": {"total": 10, "fixed": 10, "fix_ratio": 1.0,
                                "first_fix_s": 1.0, "used": 10,
                                "lat": 42.65236966, "lon": 26.43258495, "h": 208.145,
                                "std_n_m": 0.001, "std_e_m": 0.001, "std_u_m": 0.002},
                    "lat": 42.65236966, "lon": 26.43258495, "h": 208.145,
                    "rover_bytes": 1, "base_bytes": 1,
                    "started_at": "2026-10-24T14:15:43+00:00",
                    "finished_at": "2026-10-24T14:30:51+00:00"}
        def convert(lat, lon, h, frame, epoch):
            convert_calls.append((lat, lon, h, frame, epoch))
            return {"lat": lat, "lon": lon, "h": h, "method": "none",
                    "shift_m": 0.0, "shift_n_m": 0.0, "shift_e_m": 0.0,
                    "shift_u_m": 0.0, "provisional": False}
        manager = cj.CorsJobManager(lambda: RTKBaseConfig(settings),
                                    accounts_path=accounts_path, job_path=job_path,
                                    work_root=work_root, compute_fn=compute,
                                    convert_fn=convert, audit=lambda *a, **k: None)
        ok, job_id = manager.start(created1["id"])
        for _ in range(100):
            status = manager.status()
            if status["status"] != "running":
                break
            time.sleep(0.1)
        assert convert_calls[0][3] == "ITRF2020@epoch"
        assert convert_calls[0][4] == 2020.0
        assert status["conversion_epoch"] == 2020.0
        time.sleep(0.5)
        convert_calls.clear()
        acc2 = {"name": "N2", "host": "caster.example.org", "port": 2101,
                "mountpoint": "AUTO", "username": "u", "password": "p",
                "frame": "ETRF2000@2005.0"}
        created2 = ca.create_account(acc2, accounts_path)
        ok2, job_id2 = manager.start(created2["id"])
        for _ in range(100):
            status2 = manager.status()
            if status2["status"] != "running":
                break
            time.sleep(0.1)
        assert convert_calls[0][3] == "ETRF2000@2005.0"
        assert convert_calls[0][4] is None
        assert status2["conversion_epoch"] is None

test("A account store", test_a_account_store)
test("B frame conversion", test_b_frame_conversion)
test("C _decimal_year", test_c_decimal_year)
test("D job passes epoch", test_d_job_passes_epoch)
test("E fixed-epoch unchanged", test_e_fixed_epoch_unchanged)
print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(failed)
PYEOF
exit $?
