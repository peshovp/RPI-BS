#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${GM_REPO_ROOT:-$(dirname "$SCRIPT_DIR")}"

if ! command -v python3 &>/dev/null; then
    echo "SKIP: python3 not found"
    exit 0
fi

export GM_REPO_ROOT="$REPO"

python3 << 'PYEOF'
import os
import sys
import json
import time
import tempfile
import shutil
import stat
import threading
import importlib.util

repo_root = os.environ.get('GM_REPO_ROOT', '.')
module_path = os.path.join(repo_root, 'addons', 'features', 'auto_survey', 'survey_requests.py')

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

def load_module():
    try:
        spec = importlib.util.spec_from_file_location('survey_requests', module_path)
        if spec is None or spec.loader is None:
            raise ImportError(f"Cannot load module from {module_path}")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    except Exception as e:
        raise ImportError(f"Failed to load survey_requests: {e}")

try:
    sr = load_module()
except ImportError as e:
    failed += 1
    print(f"FAIL: module load: {e}")
    print(f"RESULT: {passed} passed, {failed} failed")
    sys.exit(failed)

def test_a():
    with tempfile.TemporaryDirectory() as d:
        rid = sr.submit_request('start', {'target_hours': 24}, request_dir=d)
        assert len(rid) == 32 and all(c in '0123456789abcdef' for c in rid), f"Bad id: {rid}"
        pending = os.path.join(d, 'pending')
        files = os.listdir(pending)
        json_files = [f for f in files if f.endswith('.json')]
        assert len(json_files) == 1, f"Expected 1 json file, got {len(json_files)}"
        tmp_files = [f for f in files if f.startswith('.tmp')]
        assert len(tmp_files) == 0, f"Tmp files remain: {tmp_files}"
        with open(os.path.join(pending, json_files[0])) as f:
            data = json.load(f)
        assert data['id'] == rid
        assert data['action'] == 'start'
        assert data['params'] == {'target_hours': 24}

test("A: submit_request basic", test_a)

def test_b():
    with tempfile.TemporaryDirectory() as d:
        r1 = sr.submit_request('stop', {}, request_dir=d)
        time.sleep(0.01)
        r2 = sr.submit_request('start', {}, request_dir=d)
        time.sleep(0.01)
        r3 = sr.submit_request('reset', {}, request_dir=d)
        got1 = sr.take_next_request(request_dir=d)
        got2 = sr.take_next_request(request_dir=d)
        got3 = sr.take_next_request(request_dir=d)
        got4 = sr.take_next_request(request_dir=d)
        assert got1['id'] == r1, f"First should be stop, got {got1['id']}"
        assert got2['id'] == r2, f"Second should be start, got {got2['id']}"
        assert got3['id'] == r3, f"Third should be reset, got {got3['id']}"
        assert got4 is None, f"Fourth should be None, got {got4}"
        pending = os.path.join(d, 'pending')
        assert len(os.listdir(pending)) == 0, "Pending should be empty"

test("B: FIFO ordering", test_b)

def test_c():
    with tempfile.TemporaryDirectory() as d:
        try:
            sr.submit_request('explode', {}, request_dir=d)
            assert False, "Should have raised ValueError"
        except ValueError:
            pass
        try:
            sr.submit_request('start', params='x', request_dir=d)
            assert False, "Should have raised ValueError"
        except ValueError:
            pass
        pending = os.path.join(d, 'pending')
        assert len(os.listdir(pending) if os.path.isdir(pending) else []) == 0, "Nothing should be written"

test("C: validation", test_c)

def test_d():
    with tempfile.TemporaryDirectory() as d:
        pending = os.path.join(d, 'pending')
        os.makedirs(pending, exist_ok=True)
        with open(os.path.join(pending, '00000000000000000000-corrupt.json'), 'w') as f:
            f.write('not json')
        with open(os.path.join(pending, '00000000000000000000-badaction.json'), 'w') as f:
            json.dump({"id": "x", "action": "explode", "params": {}}, f)
        rid = sr.submit_request('stop', {}, request_dir=d)
        got = sr.take_next_request(request_dir=d)
        assert got is not None and got['id'] == rid, f"Should get valid request, got {got}"
        rejected = os.path.join(d, 'rejected')
        rejected_files = os.listdir(rejected)
        assert len(rejected_files) == 2, f"Expected 2 rejected files, got {len(rejected_files)}"
        pending_files = os.listdir(pending)
        assert len(pending_files) == 0, "Pending should be empty"

test("D: corrupt files", test_d)

def test_e():
    got = sr.take_next_request(request_dir='/tmp/nonexistent_survey_dir_12345')
    assert got is None, f"Should return None, got {got}"

test("E: take_next on non-existent dir", test_e)

def test_f():
    with tempfile.TemporaryDirectory() as d:
        rid = 'test-rid-123'
        sr.write_result(rid, True, 'done', {'a': 1}, request_dir=d)
        result = sr.wait_for_result(rid, timeout=2, request_dir=d)
        assert result is not None
        assert result['ok'] is True
        assert result['message'] == 'done'
        assert result['data'] == {'a': 1}
        assert result['id'] == rid
        results_dir = os.path.join(d, 'results')
        result_files = [f for f in os.listdir(results_dir) if f.startswith(rid)]
        assert len(result_files) == 0, "Result file should be deleted"
        result2 = sr.wait_for_result(rid, timeout=0.3, request_dir=d)
        assert result2 is None, "Second wait should return None"

test("F: write_result and wait_for_result", test_f)

def test_g():
    with tempfile.TemporaryDirectory() as d:
        rid = 'test-rid-timeout'
        start = time.time()
        result = sr.wait_for_result(rid, timeout=0.5, request_dir=d)
        elapsed = time.time() - start
        assert result is None, f"Should return None, got {result}"
        assert elapsed >= 0.45 and elapsed < 5.0, f"Elapsed {elapsed}s, expected ~0.5s"

test("G: wait_for_result timeout", test_g)

def test_h():
    with tempfile.TemporaryDirectory() as d:
        rid = 'test-rid-concurrent'
        def write_later():
            sr.write_result(rid, True, 'concurrent', {}, request_dir=d)
        timer = threading.Timer(0.3, write_later)
        timer.start()
        start = time.time()
        result = sr.wait_for_result(rid, timeout=3, request_dir=d)
        elapsed = time.time() - start
        timer.join()
        assert result is not None
        assert result['ok'] is True
        assert result['message'] == 'concurrent'
        assert elapsed < 3.0, f"Took {elapsed}s, expected < 3.0s"

test("H: concurrency", test_h)

def test_i():
    with tempfile.TemporaryDirectory() as d:
        results_dir = os.path.join(d, 'results')
        rejected_dir = os.path.join(d, 'rejected')
        os.makedirs(results_dir, exist_ok=True)
        os.makedirs(rejected_dir, exist_ok=True)
        old_result = os.path.join(results_dir, 'old.json')
        with open(old_result, 'w') as f:
            json.dump({"id": "old"}, f)
        old_rejected = os.path.join(rejected_dir, 'old.json')
        with open(old_rejected, 'w') as f:
            json.dump({"id": "old"}, f)
        old_time = time.time() - 7200
        os.utime(old_result, (old_time, old_time))
        os.utime(old_rejected, (old_time, old_time))
        new_result = os.path.join(results_dir, 'new.json')
        with open(new_result, 'w') as f:
            json.dump({"id": "new"}, f)
        removed = sr.cleanup_stale(3600, request_dir=d)
        assert removed == 2, f"Expected 2 removed, got {removed}"
        assert not os.path.exists(old_result), "Old result should be removed"
        assert not os.path.exists(old_rejected), "Old rejected should be removed"
        assert os.path.exists(new_result), "New result should remain"
        removed2 = sr.cleanup_stale(3600, request_dir='/tmp/nonexistent_cleanup_dir')
        assert removed2 == 0, f"Expected 0, got {removed2}"

test("I: cleanup_stale", test_i)

def test_j():
    with tempfile.TemporaryDirectory() as d:
        sr.submit_request('start', {}, request_dir=d)
        for subdir in ['pending', 'results', 'rejected']:
            path = os.path.join(d, subdir)
            assert os.path.exists(path), f"{subdir} should exist"
            mode = stat.S_IMODE(os.stat(path).st_mode)
            assert mode == 0o700, f"{subdir} mode {oct(mode)}, expected 0o700"

test("J: directory permissions", test_j)

def test_k():
    with tempfile.TemporaryDirectory() as d:
        rid = sr.submit_request('start', {}, request_dir=d)
        assert sr.cancel_request(rid, request_dir=d) is True, "Cancel should return True"
        assert sr.take_next_request(request_dir=d) is None, "Request should be gone"
        assert sr.cancel_request(rid, request_dir=d) is False, "Cancel again should return False"
        assert sr.cancel_request('unknown-id', request_dir=d) is False, "Unknown id should return False"
        rid2 = sr.submit_request('stop', {}, request_dir=d)
        got = sr.take_next_request(request_dir=d)
        assert got is not None and got['id'] == rid2, "Should take the request"
        assert sr.cancel_request(rid2, request_dir=d) is False, "Cancel after take should return False"

test("K: cancel_request", test_k)

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(failed)
PYEOF

exit $?
