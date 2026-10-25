#!/usr/bin/env bash
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export GM_REPO_ROOT="$REPO"

python3 << 'PYEOF'
import os
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

repo = os.environ["GM_REPO_ROOT"]
sys.path.insert(0, repo)
sys.path.insert(0, os.path.join(repo, "tests"))

import cors_fakes as cf
cf.install_stubs()

from addons.features.auto_survey import rinex_converter as rc

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

def make_converter(tmp):
    convbin = tmp / "convbin"
    convbin.write_bytes(b"#!/bin/sh\nexit 0\n")
    convbin.chmod(0o755)
    return rc.RINEXConverter(convbin_path=str(convbin))

def seg(tmp, name):
    p = tmp / name
    p.touch()
    return p

def patch(conv, ok_names, calls):
    original_convert = conv.convert_raw_to_rinex_obs
    original_merge = rc.merge_rinex_obs
    merged = []

    def fake_convert(raw_file, out_dir, **kw):
        calls.append(raw_file.name)
        if raw_file.name in ok_names:
            out_dir.mkdir(parents=True, exist_ok=True)
            obs = out_dir / f"{raw_file.name}.obs"
            nav = out_dir / f"{raw_file.name}.nav"
            obs.touch()
            nav.touch()
            return (obs, nav)
        return None

    def fake_merge(obs_files, output_path):
        merged.extend([f.name for f in obs_files])
        output_path.touch()
        return output_path

    conv.convert_raw_to_rinex_obs = fake_convert
    rc.merge_rinex_obs = fake_merge

    def restore():
        conv.convert_raw_to_rinex_obs = original_convert
        rc.merge_rinex_obs = original_merge

    return restore, merged

T0 = datetime(2026, 10, 23, 21, 6, 29)
T1 = T0 + timedelta(hours=1)

def test_a():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        conv = make_converter(tmp)
        seg1 = seg(tmp, "2026-10-23_16-55-05_GNSS-1.ubx")
        seg2 = seg(tmp, "2026-10-23_21-06-49_GNSS-1.ubx")
        calls = []
        restore, merged = patch(conv, {"2026-10-23_21-06-49_GNSS-1.ubx"}, calls)
        try:
            result = conv.convert_raw_files_to_rinex_obs([seg1, seg2], tmp / "out", time_start=T0, time_end=T1)
            assert result is not None, "result should not be None"
            assert result[0].name == "2026-10-23_21-06-49_GNSS-1.ubx.obs", f"wrong obs name: {result[0].name}"
            assert len(merged) == 0, "merge should not be called"
            assert len(calls) == 2, "both segments should be attempted"
        finally:
            restore()

test("A leading empty segment skipped", test_a)

def test_b():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        conv = make_converter(tmp)
        seg1 = seg(tmp, "2026-10-23_16-55-05_GNSS-1.ubx")
        seg2 = seg(tmp, "2026-10-23_21-06-49_GNSS-1.ubx")
        calls = []
        restore, merged = patch(conv, {"2026-10-23_21-06-49_GNSS-1.ubx"}, calls)
        try:
            result = conv.convert_raw_files_to_rinex_obs([seg1, seg2], tmp / "out", time_start=datetime(2026, 10, 23, 21, 0, 0), time_end=T1)
            assert result is None, "result should be None (gap too large)"
        finally:
            restore()

test("B gap too large", test_b)

def test_c():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        conv = make_converter(tmp)
        seg1 = seg(tmp, "2026-10-23_16-55-05_GNSS-1.ubx")
        seg2 = seg(tmp, "2026-10-23_21-06-49_GNSS-1.ubx")
        calls = []
        restore, merged = patch(conv, {"2026-10-23_21-06-49_GNSS-1.ubx"}, calls)
        try:
            result = conv.convert_raw_files_to_rinex_obs([seg1, seg2], tmp / "out", time_start=None, time_end=None)
            assert result is None, "result should be None (no window, first fails)"
        finally:
            restore()

test("C no window", test_c)

def test_d():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        conv = make_converter(tmp)
        seg1 = seg(tmp, "2026-10-23_16-55-05_GNSS-1.ubx")
        seg2 = seg(tmp, "2026-10-23_18-00-00_GNSS-1.ubx")
        seg3 = seg(tmp, "2026-10-23_21-06-49_GNSS-1.ubx")
        calls = []
        ok_names = {"2026-10-23_18-00-00_GNSS-1.ubx", "2026-10-23_21-06-49_GNSS-1.ubx"}
        restore, merged = patch(conv, ok_names, calls)
        try:
            result = conv.convert_raw_files_to_rinex_obs([seg1, seg2, seg3], tmp / "out", time_start=T0, time_end=T1)
            assert result is not None, "D1: result should not be None"
            assert len(merged) == 2, "D1: merge should be called with 2 obs files"
            assert merged[0] == "2026-10-23_18-00-00_GNSS-1.ubx.obs", f"D1: wrong first merged: {merged[0]}"
            assert merged[1] == "2026-10-23_21-06-49_GNSS-1.ubx.obs", f"D1: wrong second merged: {merged[1]}"
        finally:
            restore()

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        conv = make_converter(tmp)
        seg1 = seg(tmp, "2026-10-23_16-55-05_GNSS-1.ubx")
        seg2 = seg(tmp, "2026-10-23_18-00-00_GNSS-1.ubx")
        seg3 = seg(tmp, "2026-10-23_21-06-49_GNSS-1.ubx")
        calls = []
        ok_names = {"2026-10-23_16-55-05_GNSS-1.ubx", "2026-10-23_21-06-49_GNSS-1.ubx"}
        restore, merged = patch(conv, ok_names, calls)
        try:
            result = conv.convert_raw_files_to_rinex_obs([seg1, seg2, seg3], tmp / "out", time_start=T0, time_end=T1)
            assert result is not None, "D2: result should not be None"
            assert len(merged) == 2, "D2: merge should be called with 2 obs files"
            assert merged[0] == "2026-10-23_16-55-05_GNSS-1.ubx.obs", f"D2: wrong first merged: {merged[0]}"
            assert merged[1] == "2026-10-23_21-06-49_GNSS-1.ubx.obs", f"D2: wrong second merged: {merged[1]}"
        finally:
            restore()

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        conv = make_converter(tmp)
        seg1 = seg(tmp, "2026-10-23_16-55-05_GNSS-1.ubx")
        seg2 = seg(tmp, "2026-10-23_18-00-00_GNSS-1.ubx")
        seg3 = seg(tmp, "2026-10-23_21-06-49_GNSS-1.ubx")
        calls = []
        ok_names = {"2026-10-23_16-55-05_GNSS-1.ubx", "2026-10-23_18-00-00_GNSS-1.ubx"}
        restore, merged = patch(conv, ok_names, calls)
        try:
            result = conv.convert_raw_files_to_rinex_obs([seg1, seg2, seg3], tmp / "out", time_start=T0, time_end=T1)
            assert result is None, "D3: result should be None (last segment fails)"
        finally:
            restore()

test("D last or middle failure aborts", test_d)

def test_e():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        conv = make_converter(tmp)
        seg1 = seg(tmp, "2026-10-23_16-55-05_GNSS-1.ubx")
        seg2 = seg(tmp, "2026-10-23_21-06-49_GNSS-1.ubx")
        calls = []
        ok_names = {"2026-10-23_16-55-05_GNSS-1.ubx", "2026-10-23_21-06-49_GNSS-1.ubx"}
        restore, merged = patch(conv, ok_names, calls)
        try:
            result = conv.convert_raw_files_to_rinex_obs([seg1, seg2], tmp / "out", time_start=T0, time_end=T1)
            assert result is not None, "result should not be None"
            assert len(merged) == 2, "merge should be called with 2 obs files"
            assert merged[0] == "2026-10-23_16-55-05_GNSS-1.ubx.obs", f"wrong first merged: {merged[0]}"
            assert merged[1] == "2026-10-23_21-06-49_GNSS-1.ubx.obs", f"wrong second merged: {merged[1]}"
        finally:
            restore()

test("E both succeed", test_e)

def test_f():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        conv = make_converter(tmp)
        seg1 = seg(tmp, "2026-10-23_16-55-05_GNSS-1.ubx")
        seg2 = seg(tmp, "2026-10-23_21-06-49_GNSS-1.ubx")
        calls = []
        restore, merged = patch(conv, set(), calls)
        try:
            result = conv.convert_raw_files_to_rinex_obs([seg1, seg2], tmp / "out", time_start=T0, time_end=T1)
            assert result is None, "result should be None (all fail)"
        finally:
            restore()

test("F all fail", test_f)

def test_g():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        conv = make_converter(tmp)
        seg1 = seg(tmp, "2026-10-23_16-55-05_GNSS-1.ubx")
        seg2 = seg(tmp, "2026-10-23_21-06-49_GNSS-1.ubx")
        calls = []
        restore, merged = patch(conv, {"2026-10-23_21-06-49_GNSS-1.ubx"}, calls)
        try:
            t0_aware = datetime(2026, 10, 23, 21, 6, 29, tzinfo=timezone.utc)
            result = conv.convert_raw_files_to_rinex_obs([seg1, seg2], tmp / "out", time_start=t0_aware, time_end=T1)
            assert result is not None, "result should not be None"
            assert result[0].name == "2026-10-23_21-06-49_GNSS-1.ubx.obs", f"wrong obs name: {result[0].name}"
        finally:
            restore()

test("G timezone-aware window start", test_g)

def test_h():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        conv = make_converter(tmp)
        seg1 = seg(tmp, "2026-10-23_21-06-49_GNSS-1.ubx")
        calls = []
        restore, merged = patch(conv, {"2026-10-23_21-06-49_GNSS-1.ubx"}, calls)
        try:
            result = conv.convert_raw_files_to_rinex_obs([seg1], tmp / "out", time_start=T0, time_end=T1)
            assert result is not None, "H1: result should not be None"
            assert result[0].name == "2026-10-23_21-06-49_GNSS-1.ubx.obs", f"H1: wrong obs name: {result[0].name}"
            assert len(merged) == 0, "H1: merge should not be called for single segment"
        finally:
            restore()

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        conv = make_converter(tmp)
        seg1 = seg(tmp, "2026-10-23_21-06-49_GNSS-1.ubx")
        calls = []
        restore, merged = patch(conv, set(), calls)
        try:
            result = conv.convert_raw_files_to_rinex_obs([seg1], tmp / "out", time_start=T0, time_end=T1)
            assert result is None, "H2: result should be None (single segment fails)"
        finally:
            restore()

test("H single segment path unchanged", test_h)

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(failed)
PYEOF

exit $?
