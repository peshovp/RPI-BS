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
import threading

REPO = sys.argv[1]

# Install numpy stand-in if not available
try:
    import numpy
except ImportError:
    numpy = types.ModuleType('numpy')
    numpy.bool_ = type('bool_', (), {})
    numpy.integer = type('integer', (), {})
    numpy.floating = type('floating', (), {})
    numpy.ndarray = type('ndarray', (), {})
    sys.modules['numpy'] = numpy

# Load state_manager from the repo
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

def test_atomic_save():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = os.path.join(tmpdir, 'state.json')
        sm = mod.StateManager(state_file=path)
        sm.save_state()
        assert not os.path.exists(path + '.tmp'), "tmp file still exists"
        mode = os.stat(path).st_mode & 0o777
        assert mode == 0o600, f"mode is {oct(mode)}, expected 0o600"
        with open(path) as f:
            json.load(f)

def test_two_instances():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = os.path.join(tmpdir, 'state.json')
        a = mod.StateManager(state_file=path)
        b = mod.StateManager(state_file=path)
        a.set_file_service_owned(True)
        a.save_state()
        assert not b.get_file_service_owned(), "b should not see change before reload"
        result = b.reload()
        assert result, "reload should return True"
        assert b.get_file_service_owned(), "b should see change after reload"

def test_reload_missing():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = os.path.join(tmpdir, 'state.json')
        sm = mod.StateManager(state_file=path)
        sm.set_file_service_owned(True)
        sm.save_state()
        os.remove(path)
        result = sm.reload()
        assert not result, "reload should return False for missing file"
        assert sm.get_file_service_owned(), "state should be unchanged"

def test_reload_corrupt():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = os.path.join(tmpdir, 'state.json')
        sm = mod.StateManager(state_file=path)
        sm.set_file_service_owned(True)
        sm.save_state()
        with open(path, 'w') as f:
            f.write('not json')
        sm.reload()
        sm.get_status()

def test_no_torn_reads():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = os.path.join(tmpdir, 'state.json')
        sm = mod.StateManager(state_file=path)
        sm.save_state()
        errors = [0]
        missing = [0]
        done = threading.Event()

        def writer():
            for i in range(300):
                sm.set_file_service_owned(i % 2 == 0)
                sm.save_state()
            done.set()

        def reader():
            while not done.is_set():
                try:
                    with open(path) as f:
                        json.load(f)
                except json.JSONDecodeError:
                    errors[0] += 1
                except FileNotFoundError:
                    missing[0] += 1

        t1 = threading.Thread(target=writer)
        t2 = threading.Thread(target=reader)
        t2.start()
        t1.start()
        t1.join()
        t2.join()
        assert errors[0] == 0, f"{errors[0]} JSON errors during concurrent writes"
        assert missing[0] == 0, f"{missing[0]} missing file errors"

test("atomic save", test_atomic_save)
test("two instances", test_two_instances)
test("reload missing", test_reload_missing)
test("reload corrupt", test_reload_corrupt)
test("no torn reads", test_no_torn_reads)

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(failed)
PYEOF
exit $?
