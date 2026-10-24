#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export GM_REPO_ROOT="$REPO"
python3 << 'PYEOF'
import os
import sys
import tempfile
import math

repo = os.environ["GM_REPO_ROOT"]
sys.path.insert(0, repo)
sys.path.insert(0, os.path.join(repo, "tests"))

import cors_fakes as cf
cf.install_stubs()

from addons.features.cors_position import cors_apply as ca
from addons.features.auto_survey.rtkbase_config import RTKBaseConfig

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

def make_settings(tmpdir, position="'42.65236966 26.43258495 208.145'"):
    path = os.path.join(tmpdir, "settings.conf")
    if position is None:
        content = "[general]\nuser=peshovp\n\n[main]\ncom_port='ttyS0'\n"
    else:
        content = f"[general]\nuser=peshovp\n\n[main]\nposition={position}\ncom_port='ttyS0'\n"
    with open(path, "w") as f:
        f.write(content)
    return path

class Recorder:
    def __init__(self):
        self.calls = []
        self.events = []
    def restart(self):
        self.calls.append("restart")
    def announce(self):
        self.calls.append("announce")
    def audit(self, category, event, details):
        self.events.append((category, event, details))

def read_text(path):
    with open(path, "r") as f:
        return f.read()

START = (42.65236966, 26.43258495, 208.145)

def test_small_change_applies():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = make_settings(tmpdir)
        rec = Recorder()
        rtkbase = RTKBaseConfig(path)
        lat = START[0] + 1.8e-6
        lon = START[1]
        h = START[2] + 0.01
        meta = {"account_name": "Net A", "fix_ratio": 0.9, "bad": [1, 2], "long": "x" * 300, 5: "numeric key"}
        result = ca.apply_position(rtkbase, lat, lon, h, source="cors", meta=meta,
                                   restart=rec.restart, announce=rec.announce, audit=rec.audit)
        assert result["ok"] is True, f"expected ok, got {result['reason']}"
        assert result["reason"] is None
        assert abs(result["previous"][0] - START[0]) < 1e-9
        assert abs(result["applied"][0] - lat) < 1e-9
        assert 0.15 < result["change_h_m"] < 0.25
        assert result["restart_ok"] is True
        text = read_text(path)
        assert f"{lat:.8f} {lon:.8f} {h:.3f}" in text
        assert "42.65236966 26.43258495 208.145" not in text
        assert "com_port='ttyS0'" in text
        assert "user=peshovp" in text
        assert rec.calls == ["announce", "restart"]
        assert len(rec.events) == 1
        cat, event, details = rec.events[0]
        assert cat == "cors" and event == "position_applied"
        assert details["source"] == "cors"
        assert details["forced"] is False
        assert details["meta"]["account_name"] == "Net A"
        assert details["meta"]["fix_ratio"] == 0.9
        assert len(details["meta"]["long"]) == 100
        assert "bad" not in details["meta"]
        assert 5 not in details["meta"]

def test_large_change_refused():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = make_settings(tmpdir)
        rec = Recorder()
        rtkbase = RTKBaseConfig(path)
        original = read_text(path)
        result = ca.apply_position(rtkbase, START[0] + 0.001, START[1], START[2],
                                   source="cors", restart=rec.restart, announce=rec.announce, audit=rec.audit)
        assert result["ok"] is False
        assert result["reason"] == "change too large"
        assert read_text(path) == original
        assert rec.calls == []
        assert any(e[1] == "position_apply_refused" for e in rec.events)
        result2 = ca.apply_position(rtkbase, START[0] + 0.001, START[1], START[2],
                                    source="cors", force=True, restart=rec.restart,
                                    announce=rec.announce, audit=rec.audit)
        assert result2["ok"] is True
        assert any(e[2].get("forced") is True for e in rec.events if e[1] == "position_applied")

def test_vertical_change_refused():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = make_settings(tmpdir)
        rec = Recorder()
        rtkbase = RTKBaseConfig(path)
        original = read_text(path)
        result = ca.apply_position(rtkbase, START[0], START[1], START[2] + 3.0,
                                   source="cors", restart=rec.restart, announce=rec.announce, audit=rec.audit)
        assert result["ok"] is False
        assert result["reason"] == "change too large"
        assert read_text(path) == original

def test_no_previous_position():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = make_settings(tmpdir, position=None)
        rec = Recorder()
        rtkbase = RTKBaseConfig(path)
        result = ca.apply_position(rtkbase, *START, source="cors",
                                   restart=rec.restart, announce=rec.announce, audit=rec.audit)
        assert result["ok"] is True
        assert result["previous"] is None
        assert result["change_h_m"] is None
        text = read_text(path)
        assert f"{START[0]:.8f} {START[1]:.8f} {START[2]:.3f}" in text
        assert "[main]" in text

def test_invalid_input_refused():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = make_settings(tmpdir)
        rec = Recorder()
        rtkbase = RTKBaseConfig(path)
        original = read_text(path)
        for lat, lon, h, expected_reason in [
            (float("nan"), START[1], START[2], "invalid position"),
            (True, START[1], START[2], "invalid position"),
            ("42.6", START[1], START[2], "invalid position"),
            (10.0, START[1], START[2], "position outside the expected area"),
            (START[0], 40.0, START[2], "position outside the expected area"),
            (START[0], START[1], 5000.0, "position outside the expected area"),
            (START[0], START[1], float("inf"), "invalid position"),
        ]:
            result = ca.apply_position(rtkbase, lat, lon, h, source="cors",
                                       restart=rec.restart, announce=rec.announce, audit=rec.audit)
            assert result["ok"] is False, f"expected failure for {lat},{lon},{h}"
            assert result["reason"] == expected_reason, f"wrong reason: {result['reason']}"
        assert read_text(path) == original
        assert rec.calls == []

def test_update_position_failure():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = make_settings(tmpdir)
        rec = Recorder()
        class FailingConfig(RTKBaseConfig):
            def update_position(self, lat, lon, h):
                return False
        rtkbase = FailingConfig(path)
        result = ca.apply_position(rtkbase, *START, source="cors",
                                   restart=rec.restart, announce=rec.announce, audit=rec.audit)
        assert result["ok"] is False
        assert result["reason"] == "settings.conf could not be updated"
        assert rec.calls == []

def test_verification_mismatch():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = make_settings(tmpdir)
        rec = Recorder()
        class MismatchConfig(RTKBaseConfig):
            def __init__(self, path):
                super().__init__(path)
                self.first = True
            def update_position(self, lat, lon, h):
                if self.first:
                    self.first = False
                    return super().update_position(lat + 0.01, lon, h)
                return super().update_position(lat, lon, h)
        rtkbase = MismatchConfig(path)
        result = ca.apply_position(rtkbase, *START, source="cors",
                                   restart=rec.restart, announce=rec.announce, audit=rec.audit)
        assert result["ok"] is False
        assert result["reason"] == "written position did not verify"
        text = read_text(path)
        assert f"{START[0]:.8f} {START[1]:.8f} {START[2]:.3f}" in text
        assert rec.calls == []

def test_restart_announce_exceptions():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = make_settings(tmpdir)
        rec = Recorder()
        def bad_restart():
            raise RuntimeError("boom")
        def bad_announce():
            raise RuntimeError("oops")
        rtkbase = RTKBaseConfig(path)
        result = ca.apply_position(rtkbase, *START, source="cors",
                                   restart=bad_restart, announce=bad_announce, audit=rec.audit)
        assert result["ok"] is True
        assert result["restart_ok"] is False
        text = read_text(path)
        assert f"{START[0]:.8f} {START[1]:.8f} {START[2]:.3f}" in text

def test_never_raises():
    rec = Recorder()
    result = ca.apply_position(None, *START, source="cors", audit=rec.audit)
    assert result["ok"] is False
    assert result["reason"] == "internal error"

def test_file_mode_preserved():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = make_settings(tmpdir)
        os.chmod(path, 0o640)
        before = os.stat(path).st_mode
        rec = Recorder()
        rtkbase = RTKBaseConfig(path)
        result = ca.apply_position(rtkbase, *START, source="cors",
                                   restart=rec.restart, announce=rec.announce, audit=rec.audit)
        assert result["ok"] is True
        after = os.stat(path).st_mode
        assert before == after

test("small change applies", test_small_change_applies)
test("large change refused", test_large_change_refused)
test("vertical change refused", test_vertical_change_refused)
test("no previous position", test_no_previous_position)
test("invalid input refused", test_invalid_input_refused)
test("update_position failure", test_update_position_failure)
test("verification mismatch", test_verification_mismatch)
test("restart/announce exceptions", test_restart_announce_exceptions)
test("never raises", test_never_raises)
test("file mode preserved", test_file_mode_preserved)

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(failed)
PYEOF
exit $?
