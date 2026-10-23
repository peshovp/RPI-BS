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
from datetime import datetime

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

def test_fresh_defaults():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = os.path.join(tmpdir, 'state.json')
        sm = mod.StateManager(state_file=path)
        status = sm.get_status()
        assert status['final_attempts'] == 0, f"expected 0, got {status['final_attempts']}"
        assert status['final_next_retry_at'] is None
        assert status['final_last_reason'] is None
        assert status['last_heartbeat_at'] is None

def test_migration():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = os.path.join(tmpdir, 'state.json')
        sm = mod.StateManager(state_file=path)
        sm.save_state()
        with open(path) as f:
            data = json.load(f)
        for key in ['final_attempts', 'final_next_retry_at', 'final_last_reason', 'last_heartbeat_at']:
            data.pop(key, None)
        with open(path, 'w') as f:
            json.dump(data, f)
        sm2 = mod.StateManager(state_file=path)
        status = sm2.get_status()
        assert status['final_attempts'] == 0
        assert status['final_next_retry_at'] is None
        assert status['final_last_reason'] is None
        assert status['last_heartbeat_at'] is None

def test_record_final_attempt():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = os.path.join(tmpdir, 'state.json')
        sm = mod.StateManager(state_file=path)
        result = sm.record_final_attempt(3, 'products missing', '2026-10-23T12:00:00')
        assert result is True
        sm2 = mod.StateManager(state_file=path)
        status = sm2.get_status()
        assert status['final_attempts'] == 3
        assert status['final_last_reason'] == 'products missing'
        assert status['final_next_retry_at'] == '2026-10-23T12:00:00'
        long_reason = 'x' * 600
        sm.record_final_attempt(1, long_reason, '2026-10-24T00:00:00')
        sm3 = mod.StateManager(state_file=path)
        status3 = sm3.get_status()
        assert len(status3['final_last_reason']) == 500

def test_clear_final_attempts():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = os.path.join(tmpdir, 'state.json')
        sm = mod.StateManager(state_file=path)
        sm.record_final_attempt(5, 'test', '2026-10-25T00:00:00')
        sm.clear_final_attempts()
        status = sm.get_status()
        assert status['final_attempts'] == 0
        assert status['final_next_retry_at'] is None
        assert status['final_last_reason'] is None

def test_heartbeat():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = os.path.join(tmpdir, 'state.json')
        sm = mod.StateManager(state_file=path)
        sm.record_heartbeat()
        status = sm.get_status()
        assert status['last_heartbeat_at'] is not None
        datetime.fromisoformat(status['last_heartbeat_at'])
        first = status['last_heartbeat_at']
        result = sm.record_heartbeat(min_interval_seconds=3600)
        assert result is True
        status2 = sm.get_status()
        assert status2['last_heartbeat_at'] == first
        time.sleep(0.01)
        sm.record_heartbeat(0)
        status3 = sm.get_status()
        assert status3['last_heartbeat_at'] != first

def test_reset_survey_clears_final():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = os.path.join(tmpdir, 'state.json')
        sm = mod.StateManager(state_file=path)
        sm.record_final_attempt(7, 'test', '2026-10-26T00:00:00')
        sm.reset_survey()
        status = sm.get_status()
        assert status['final_attempts'] == 0

test("fresh defaults", test_fresh_defaults)
test("migration", test_migration)
test("record final attempt", test_record_final_attempt)
test("clear final attempts", test_clear_final_attempts)
test("heartbeat", test_heartbeat)
test("reset survey clears final", test_reset_survey_clears_final)

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(failed)
PYEOF
exit $?
