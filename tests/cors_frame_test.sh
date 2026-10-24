#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export GM_REPO_ROOT="$REPO"
python3 << 'PYEOF'
import os
import sys
import math

repo = os.environ["GM_REPO_ROOT"]
sys.path.insert(0, repo)
sys.path.insert(0, os.path.join(repo, "tests"))

import cors_fakes as cf
cf.install_stubs()

from addons.features.cors_position import cors_frame as cfr

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

P = (42.65237410, 26.43259399, 208.139)

itrf_calls = []
def fake_itrf(lat, lon, h, epoch):
    itrf_calls.append((lat, lon, h, epoch))
    return {
        "lat_dd": lat - 0.60 / 111132.92,
        "lon_dd": lon - 0.89 / (111412.84 * math.cos(math.radians(lat))),
        "height_m": h + 0.007,
        "coordinate_provisional": True,
        "coordinate_provisional_reason": "proxy velocity"
    }

def test_a():
    r = cfr.to_bgs2005(*P, "ETRF2000@2005.0", None)
    assert r["lat"] == P[0], "lat not equal"
    assert r["lon"] == P[1], "lon not equal"
    assert r["h"] == P[2], "h not equal"
    assert r["method"] == "none", "method not none"
    assert abs(r["shift_m"]) < 1e-9, "shift not zero"
    assert r["provisional"] == False, "provisional should be False"
test("A identity", test_a)

def test_b():
    itrf_calls.clear()
    r = cfr.to_bgs2005(*P, "ITRF2020@epoch", 2020.0, itrf_fn=fake_itrf)
    assert len(itrf_calls) == 1, "itrf_fn not called once"
    call = itrf_calls[0]
    assert call[0] == P[0] and call[1] == P[1] and call[2] == P[2] and call[3] == 2020.0, "wrong args to itrf_fn"
    assert abs(r["shift_n_m"] - (-0.60)) < 0.005, f"shift_n_m {r['shift_n_m']} not close to -0.60"
    assert abs(r["shift_e_m"] - (-0.89)) < 0.01, f"shift_e_m {r['shift_e_m']} not close to -0.89"
    assert abs(r["shift_u_m"] - 0.007) < 0.001, f"shift_u_m {r['shift_u_m']} not close to 0.007"
    assert abs(r["shift_m"] - 1.07) < 0.01, f"shift_m {r['shift_m']} not close to 1.07"
    assert r["method"] == "itrf2020_to_bgs2005", "wrong method"
    assert r["provisional"] == True, "provisional should be True"
    assert r["provisional_reason"] == "proxy velocity", "wrong reason"
    assert r["frame_in"] == "ITRF2020@epoch", "wrong frame_in"
    assert r["epoch_in"] == 2020.0, "wrong epoch_in"
test("B ITRF with epoch", test_b)

epoch_calls = []
def fake_epoch_fn(lat, lon, h, epoch, target, velocity):
    epoch_calls.append((lat, lon, h, epoch, target, velocity))
    return (lat + 1e-8, lon + 1e-8, h - 0.001)

def fake_velocity_fn():
    return {"north": 0.5, "east": 0.2, "up": -0.4}

def test_c():
    epoch_calls.clear()
    r = cfr.to_bgs2005(*P, "ETRF2000@epoch", 2026.8, epoch_fn=fake_epoch_fn, velocity_fn=fake_velocity_fn)
    assert len(epoch_calls) == 1, "epoch_fn not called once"
    call = epoch_calls[0]
    assert call[3] == 2026.8, "wrong epoch"
    assert call[4] == 2005.0, "wrong target"
    assert call[5] == {"north": 0.5, "east": 0.2, "up": -0.4}, "wrong velocity"
    assert r["method"] == "etrf2000_epoch_reduction", "wrong method"
    assert r["provisional"] == True, "provisional should be True"
test("C ETRF2000@epoch", test_c)

def test_d():
    try:
        cfr.to_bgs2005(*P, "ITRF2020@epoch", None)
        assert False, "should have raised"
    except cfr.FrameError as e:
        assert "42.65237410" not in str(e), "position leaked in error"
    try:
        cfr.to_bgs2005(*P, "ITRF2020@epoch", 1800.0)
        assert False, "should have raised"
    except cfr.FrameError as e:
        assert "42.65237410" not in str(e), "position leaked in error"
    try:
        cfr.to_bgs2005(*P, "ITRF2020@epoch", True)
        assert False, "should have raised"
    except cfr.FrameError as e:
        assert "42.65237410" not in str(e), "position leaked in error"
    try:
        cfr.to_bgs2005(*P, "ETRF2000@epoch", None)
        assert False, "should have raised"
    except cfr.FrameError as e:
        assert "42.65237410" not in str(e), "position leaked in error"
    try:
        cfr.to_bgs2005(*P, "WGS84-approx", None)
        assert False, "should have raised"
    except cfr.FrameError as e:
        assert "WGS84" in str(e), "WGS84 not mentioned"
    try:
        cfr.to_bgs2005(*P, "FOO", None)
        assert False, "should have raised"
    except cfr.FrameError as e:
        assert "42.65237410" not in str(e), "position leaked in error"
    try:
        cfr.to_bgs2005(float("nan"), P[1], P[2], "ETRF2000@2005.0", None)
        assert False, "should have raised"
    except cfr.FrameError as e:
        assert "42.65237410" not in str(e), "position leaked in error"
    try:
        cfr.to_bgs2005(True, P[1], P[2], "ETRF2000@2005.0", None)
        assert False, "should have raised"
    except cfr.FrameError as e:
        assert "42.65237410" not in str(e), "position leaked in error"
    try:
        cfr.to_bgs2005(P[0], P[1], "x", "ETRF2000@2005.0", None)
        assert False, "should have raised"
    except cfr.FrameError as e:
        assert "42.65237410" not in str(e), "position leaked in error"
test("D validation errors", test_d)

def test_e():
    def big_shift_itrf(lat, lon, h, epoch):
        return {
            "lat_dd": lat + 50.0 / 111132.92,
            "lon_dd": lon,
            "height_m": h,
            "coordinate_provisional": False,
            "coordinate_provisional_reason": None
        }
    try:
        cfr.to_bgs2005(*P, "ITRF2020@epoch", 2020.0, itrf_fn=big_shift_itrf)
        assert False, "should have raised"
    except cfr.FrameError as e:
        assert str(e) == "implausible frame shift", f"wrong error: {e}"
    def nan_itrf(lat, lon, h, epoch):
        return {
            "lat_dd": float("nan"),
            "lon_dd": lon,
            "height_m": h,
            "coordinate_provisional": False,
            "coordinate_provisional_reason": None
        }
    try:
        cfr.to_bgs2005(*P, "ITRF2020@epoch", 2020.0, itrf_fn=nan_itrf)
        assert False, "should have raised"
    except cfr.FrameError as e:
        assert "42.65237410" not in str(e), "position leaked in error"
    def raise_itrf(lat, lon, h, epoch):
        raise RuntimeError("secret")
    try:
        cfr.to_bgs2005(*P, "ITRF2020@epoch", 2020.0, itrf_fn=raise_itrf)
        assert False, "should have raised"
    except cfr.FrameError as e:
        assert str(e) == "the frame conversion failed", f"wrong error: {e}"
test("E plausibility", test_e)

def test_f():
    itrf_calls.clear()
    r = cfr.to_bgs2005(*P, "ITRF2020@epoch", 2020.0, itrf_fn=fake_itrf)
    assert 1.05 < r["shift_m"] < 1.10, f"shift_m {r['shift_m']} not in range"
test("F ECEF distance", test_f)

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(failed)
PYEOF
exit $?
