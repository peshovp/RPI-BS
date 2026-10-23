#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${GM_REPO_ROOT:-$(dirname "$SCRIPT_DIR")}"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not found"
    exit 0
fi

python3 - "$REPO" <<'PYEOF'
import sys
import os
import tempfile
import time
import subprocess
import importlib.util

repo_root = sys.argv[1]

module_path = os.path.join(repo_root, 'addons', 'features', 'auto_survey', 'process_group.py')
try:
    spec = importlib.util.spec_from_file_location('process_group', module_path)
    pg = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pg)
except Exception as e:
    print(f"FAIL: module load: {e}")
    print("RESULT: 0 passed, 1 failed")
    sys.exit(1)

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

def test_a():
    result = pg.run_in_process_group(['bash', '-c', 'echo out; echo err >&2; exit 3'], timeout=10)
    assert result.returncode == 3, f"expected 3, got {result.returncode}"
    assert result.stdout == 'out\n', f"expected 'out\\n', got {repr(result.stdout)}"
    assert result.stderr == 'err\n', f"expected 'err\\n', got {repr(result.stderr)}"

def test_b():
    with tempfile.TemporaryDirectory() as tmpdir:
        env = {**os.environ, 'GM_TEST_VAR': 'xyz'}
        result = pg.run_in_process_group(['bash', '-c', 'pwd; echo $GM_TEST_VAR'], timeout=10, cwd=tmpdir, env=env)
        lines = result.stdout.strip().split('\n')
        assert lines[0] == os.path.realpath(tmpdir), f"expected {os.path.realpath(tmpdir)}, got {lines[0]}"
        assert lines[1] == 'xyz', f"expected 'xyz', got {lines[1]}"

def test_c():
    with tempfile.TemporaryDirectory() as tmpdir:
        pid_file = os.path.join(tmpdir, 'pid')
        pid_file2 = os.path.join(tmpdir, 'pid2')
        pid = None
        pid2 = None
        try:
            try:
                pg.run_in_process_group(['bash', '-c', f'sleep 300 & echo $! > {pid_file}; wait'], timeout=1)
                assert False, "expected TimeoutExpired"
            except subprocess.TimeoutExpired:
                pass

            with open(pid_file) as f:
                pid = int(f.read().strip())

            def process_gone(p):
                try:
                    os.kill(p, 0)
                    try:
                        with open(f'/proc/{p}/stat') as sf:
                            parts = sf.read().split()
                            if parts[2] == 'Z':
                                return True
                    except FileNotFoundError:
                        return True
                    return False
                except ProcessLookupError:
                    return True

            for i in range(50):
                if process_gone(pid):
                    break
                time.sleep(0.1)
            else:
                assert False, f"process {pid} still alive after timeout"

            try:
                subprocess.run(['bash', '-c', f'sleep 300 & echo $! > {pid_file2}; wait'], timeout=1, capture_output=True)
                assert False, "expected TimeoutExpired"
            except subprocess.TimeoutExpired:
                pass

            with open(pid_file2) as f:
                pid2 = int(f.read().strip())

            try:
                os.kill(pid2, 0)
            except ProcessLookupError:
                assert False, "process should still be alive (bug demonstration)"
        finally:
            if pid2 is not None:
                try:
                    os.kill(pid2, 9)
                except ProcessLookupError:
                    pass

def test_d():
    try:
        pg.run_in_process_group(['bash', '-c', 'echo started; sleep 300'], timeout=1)
        assert False, "expected TimeoutExpired"
    except subprocess.TimeoutExpired as e:
        output = e.output
        if isinstance(output, bytes):
            output = output.decode()
        assert 'started' in output, f"expected 'started' in output, got {repr(output)}"

def test_e():
    with tempfile.TemporaryDirectory() as tmpdir:
        pid_file = os.path.join(tmpdir, 'pid')
        start = time.time()
        try:
            pg.run_in_process_group(['bash', '-c', f'trap "" TERM; sleep 300 & echo $! > {pid_file}; wait'], timeout=1, kill_grace_seconds=1.0)
            assert False, "expected TimeoutExpired"
        except subprocess.TimeoutExpired:
            pass
        elapsed = time.time() - start
        assert elapsed < 6, f"took {elapsed}s, expected < 6s"

        with open(pid_file) as f:
            pid = int(f.read().strip())

        for i in range(50):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.1)
        else:
            try:
                os.kill(pid, 9)
            except ProcessLookupError:
                pass
            assert False, f"process {pid} still alive"

def test_f():
    result = pg.run_in_process_group(['bash', '-c', 'exit 0'], timeout=10, capture_output=False)
    assert result.returncode == 0
    assert result.stdout is None

test("A: normal command", test_a)
test("B: cwd and env", test_b)
test("C: orphan children killed", test_c)
test("D: partial output on timeout", test_d)
test("E: elapsed time bounded", test_e)
test("F: capture_output=False", test_f)

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(failed)
PYEOF

exit $?
