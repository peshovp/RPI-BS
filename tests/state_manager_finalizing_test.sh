#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${GM_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not found"
    exit 0
fi

python3 - "$REPO" <<'PYEOF'
import sys
import os
import json
import tempfile
import importlib
import importlib.util
import types
import time
from datetime import datetime, timedelta

REPO = sys.argv[1]

try:
    import numpy
except ImportError:
    numpy = types.ModuleType('numpy')
    numpy.bool_ = type('bool_', (), {})
    numpy.integer = type('integer', (), {})
    numpy.floating = type('floating', (), {})
    numpy.ndarray = type('ndarray', (), {})
    sys.modules['numpy'] = numpy

path = os.path.join(REPO, 'addons', 'features', 'auto_survey', 'state_manager.py')
spec = importlib.util.spec_from_file_location('state_manager', path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

passed = 0
failed = 0

def test(name, fn):
    global passed, failed
    try:
        fn()
        print(f"PASS: {name}")
        passed += 1
    except Exception as e:
        print(f"FAIL: {name} - {e}")
        failed += 1

def test_enum():
    assert mod.SurveyState.FINALIZING.value == 'finalizing'

def test_begin_finalizing():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = os.path.join(tmpdir, 'state.json')
        sm = mod.StateManager(state_file=path)
        sm.start_survey(target_hours=24)
        result = sm.begin_finalizing()
        assert result is True
        assert sm.survey_state == mod.SurveyState.FINALIZING
        result2 = sm.begin_finalizing()
        assert result2 is True
        sm2 = mod.StateManager(state_file=os.path.join(tmpdir, 'state2.json'))
        result3 = sm2.begin_finalizing()
        assert result3 is False
        assert sm2.survey_state == mod.SurveyState.IDLE

def test_start_while_finalizing():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = os.path.join(tmpdir, 'state.json')
        sm = mod.StateManager(state_file=path)
        sm.start_survey(target_hours=24)
        sm.begin_finalizing()
        result = sm.start_survey(target_hours=12)
        assert result is False
        assert sm.survey_state == mod.SurveyState.FINALIZING

def test_pause_while_finalizing():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = os.path.join(tmpdir, 'state.json')
        sm = mod.StateManager(state_file=path)
        sm.start_survey(target_hours=24)
        sm.begin_finalizing()
        result = sm.pause_survey()
        assert result is True
        assert sm.survey_state == mod.SurveyState.PAUSED

def test_complete_while_finalizing():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = os.path.join(tmpdir, 'state.json')
        sm = mod.StateManager(state_file=path)
        sm.start_survey(target_hours=24)
        sm.begin_finalizing()
        pos = {'lat': 42.0, 'lon': 24.0, 'height': 500.0}
        sm.complete_survey(pos)
        assert sm.survey_state == mod.SurveyState.COMPLETED

def test_can_recover():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = os.path.join(tmpdir, 'state.json')
        sm = mod.StateManager(state_file=path)
        sm.start_survey(target_hours=24)
        sm._state['start_time'] = (datetime.now() - timedelta(hours=1)).isoformat()
        assert sm.can_recover() is True
        sm._state['start_time'] = (datetime.now() - timedelta(hours=200)).isoformat()
        assert sm.can_recover() is False
        sm.begin_finalizing()
        assert sm.can_recover() is True
        sm2 = mod.StateManager(state_file=os.path.join(tmpdir, 'state2.json'))
        sm2.start_survey(target_hours=24)
        sm2._state['start_time'] = (datetime.now() - timedelta(hours=1)).isoformat()
        sm2.pause_survey()
        assert sm2.can_recover() is False
        sm3 = mod.StateManager(state_file=os.path.join(tmpdir, 'state3.json'))
        sm3.start_survey(target_hours=24)
        sm3.begin_finalizing()
        sm3._state['start_time'] = None
        assert sm3.can_recover() is False

def test_persistence():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = os.path.join(tmpdir, 'state.json')
        sm = mod.StateManager(state_file=path)
        sm.start_survey(target_hours=24)
        sm.begin_finalizing()
        sm.save_state()
        sm2 = mod.StateManager(state_file=path)
        assert sm2.survey_state == mod.SurveyState.FINALIZING

test("enum", test_enum)
test("begin finalizing", test_begin_finalizing)
test("start while finalizing", test_start_while_finalizing)
test("pause while finalizing", test_pause_while_finalizing)
test("complete while finalizing", test_complete_while_finalizing)
test("can recover", test_can_recover)
test("persistence", test_persistence)

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(failed)
PYEOF
exit $?
