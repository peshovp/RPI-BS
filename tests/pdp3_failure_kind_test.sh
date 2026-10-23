#!/usr/bin/env bash
set -uo pipefail

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not available"
    exit 0
fi

python3 - "$REPO" <<'PYEOF'
import sys
import os
import importlib.util
import tempfile
import types
import shutil
from pathlib import Path

REPO = sys.argv[1]

# Load the real module
module_path = os.environ.get('GM_PDP3_MODULE')
if not module_path:
    module_path = os.path.join(REPO, 'addons', 'features', 'auto_survey', 'pride_pppar_processor' + '.py')

spec = importlib.util.spec_from_file_location('pride_pppar_processor', module_path)
mod = importlib.util.module_from_spec(spec)
sys.modules['pride_pppar_processor'] = mod
spec.loader.exec_module(mod)

PASS = 0
FAIL = 0

def ok(msg):
    global PASS
    PASS += 1
    print(f"PASS: {msg}")

def bad(msg):
    global FAIL
    FAIL += 1
    print(f"FAIL: {msg}")

# Case A: helper function tests
try:
    if mod._looks_like_product_download_failure('error: PrepareProducts failed', ''):
        ok("A1: PrepareProducts failure detected")
    else:
        bad("A1: PrepareProducts failure not detected")
except Exception as e:
    bad(f"A1: exception: {e}")

try:
    if mod._looks_like_product_download_failure('', 'ERROR: failed to download orbit'):
        ok("A2: download orbit failure detected")
    else:
        bad("A2: download orbit failure not detected")
except Exception as e:
    bad(f"A2: exception: {e}")

try:
    if not mod._looks_like_product_download_failure('error: something else', ''):
        ok("A3: generic error not flagged as product download")
    else:
        bad("A3: generic error incorrectly flagged")
except Exception as e:
    bad(f"A3: exception: {e}")

try:
    if not mod._looks_like_product_download_failure('', 'curl: (28) Timeout was reached'):
        ok("A4: curl timeout not flagged as product download")
    else:
        bad("A4: curl timeout incorrectly flagged")
except Exception as e:
    bad(f"A4: exception: {e}")

try:
    if not mod._looks_like_product_download_failure(None, None):
        ok("A5: None inputs not flagged")
    else:
        bad("A5: None inputs incorrectly flagged")
except Exception as e:
    bad(f"A5: exception: {e}")

try:
    if not mod._looks_like_product_download_failure('warning: download slow', ''):
        ok("A6: warning not flagged as failure")
    else:
        bad("A6: warning incorrectly flagged")
except Exception as e:
    bad(f"A6: exception: {e}")

# Setup for process_ppp_ar tests
def make_processor():
    p = mod.PridePpparProcessor.__new__(mod.PridePpparProcessor)
    p.pdp3 = Path('/x/pdp3')
    return p

def make_test_env():
    tmp = tempfile.mkdtemp()
    obs_file = Path(tmp) / 'site0010.26o'
    obs_file.write_text('test obs data')
    work_dir = Path(tmp) / 'work'
    work_dir.mkdir()
    return tmp, obs_file, work_dir

# Save original functions
orig_select = mod.select_frequency_combination
orig_run = mod.run_in_process_group

# Replace select_frequency_combination
mod.select_frequency_combination = lambda f: {'frq': ['G12', 'R12', 'E17'], 'sys': 'GRE', 'fallback': False, 'bands': {}, 'reasons': {}}

# Case B: timeout
try:
    tmp, obs_file, work_dir = make_test_env()
    p = make_processor()
    
    def fake_run_timeout(*args, **kwargs):
        raise mod.subprocess.TimeoutExpired(cmd='x', timeout=1)
    
    mod.run_in_process_group = fake_run_timeout
    result = p.process_ppp_ar(obs_file, work_dir)
    if result is None and p._last_failure_kind == 'timeout':
        ok("B: timeout failure kind set")
    else:
        bad(f"B: unexpected result {result} or kind {p._last_failure_kind}")
except Exception as e:
    bad(f"B: exception: {e}")
finally:
    mod.run_in_process_group = orig_run
    shutil.rmtree(tmp)

# Case C: exception
try:
    tmp, obs_file, work_dir = make_test_env()
    p = make_processor()
    
    def fake_run_exception(*args, **kwargs):
        raise OSError('boom')
    
    mod.run_in_process_group = fake_run_exception
    result = p.process_ppp_ar(obs_file, work_dir)
    if result is None and p._last_failure_kind == 'exception':
        ok("C: exception failure kind set")
    else:
        bad(f"C: unexpected result {result} or kind {p._last_failure_kind}")
except Exception as e:
    bad(f"C: exception: {e}")
finally:
    mod.run_in_process_group = orig_run
    shutil.rmtree(tmp)

# Case D: product download failure via stdout
try:
    tmp, obs_file, work_dir = make_test_env()
    p = make_processor()
    
    def fake_run_product_fail(*args, **kwargs):
        return types.SimpleNamespace(returncode=1, stdout='error: PrepareProducts failed', stderr='')
    
    mod.run_in_process_group = fake_run_product_fail
    result = p.process_ppp_ar(obs_file, work_dir)
    if result is None and p._last_failure_kind == 'product_download':
        ok("D: product download failure kind set")
    else:
        bad(f"D: unexpected result {result} or kind {p._last_failure_kind}")
except Exception as e:
    bad(f"D: exception: {e}")
finally:
    mod.run_in_process_group = orig_run
    shutil.rmtree(tmp)

# Case E: nonzero exit
try:
    tmp, obs_file, work_dir = make_test_env()
    p = make_processor()
    
    def fake_run_nonzero(*args, **kwargs):
        return types.SimpleNamespace(returncode=1, stdout='whatever', stderr='')
    
    mod.run_in_process_group = fake_run_nonzero
    result = p.process_ppp_ar(obs_file, work_dir)
    if result is None and p._last_failure_kind == 'nonzero_exit':
        ok("E: nonzero exit failure kind set")
    else:
        bad(f"E: unexpected result {result} or kind {p._last_failure_kind}")
except Exception as e:
    bad(f"E: exception: {e}")
finally:
    mod.run_in_process_group = orig_run
    shutil.rmtree(tmp)

# Case F: product download failure via stdout with returncode 0
try:
    tmp, obs_file, work_dir = make_test_env()
    p = make_processor()
    
    def fake_run_product_fail_rc0(*args, **kwargs):
        return types.SimpleNamespace(returncode=0, stdout='error: download of clock product failed', stderr='')
    
    mod.run_in_process_group = fake_run_product_fail_rc0
    result = p.process_ppp_ar(obs_file, work_dir)
    if result is None and p._last_failure_kind == 'product_download':
        ok("F: product download failure kind set (rc=0)")
    else:
        bad(f"F: unexpected result {result} or kind {p._last_failure_kind}")
except Exception as e:
    bad(f"F: exception: {e}")
finally:
    mod.run_in_process_group = orig_run
    shutil.rmtree(tmp)

# Case G: no pos file
try:
    tmp, obs_file, work_dir = make_test_env()
    p = make_processor()
    
    def fake_run_ok_no_pos(*args, **kwargs):
        return types.SimpleNamespace(returncode=0, stdout='ok', stderr='')
    
    mod.run_in_process_group = fake_run_ok_no_pos
    result = p.process_ppp_ar(obs_file, work_dir)
    if result is None and p._last_failure_kind == 'no_pos_file':
        ok("G: no pos file failure kind set")
    else:
        bad(f"G: unexpected result {result} or kind {p._last_failure_kind}")
except Exception as e:
    bad(f"G: exception: {e}")
finally:
    mod.run_in_process_group = orig_run
    shutil.rmtree(tmp)

# Case H: success
try:
    tmp, obs_file, work_dir = make_test_env()
    p = make_processor()
    
    # Create the pos file that process_ppp_ar expects
    pos_file = work_dir / 'pos_2026001_test'
    pos_file.write_text('test pos data')
    
    def fake_run_ok(*args, **kwargs):
        return types.SimpleNamespace(returncode=0, stdout='ok', stderr='')
    
    mod.run_in_process_group = fake_run_ok
    result = p.process_ppp_ar(obs_file, work_dir)
    if result == pos_file and p._last_failure_kind is None:
        ok("H: success returns pos file path")
    else:
        bad(f"H: unexpected result {result} or kind {p._last_failure_kind}")
except Exception as e:
    bad(f"H: exception: {e}")
finally:
    mod.run_in_process_group = orig_run
    shutil.rmtree(tmp)

# Case I: staleness - kind is cleared on success
try:
    tmp, obs_file, work_dir = make_test_env()
    p = make_processor()
    
    # First, set a failure kind
    def fake_run_fail(*args, **kwargs):
        return types.SimpleNamespace(returncode=1, stdout='error: PrepareProducts failed', stderr='')
    
    mod.run_in_process_group = fake_run_fail
    p.process_ppp_ar(obs_file, work_dir)
    
    # Now succeed
    pos_file = work_dir / 'pos_2026001_test'
    pos_file.write_text('test pos data')
    
    def fake_run_ok2(*args, **kwargs):
        return types.SimpleNamespace(returncode=0, stdout='ok', stderr='')
    
    mod.run_in_process_group = fake_run_ok2
    result = p.process_ppp_ar(obs_file, work_dir)
    if result == pos_file and p._last_failure_kind is None:
        ok("I: failure kind cleared on success")
    else:
        bad(f"I: unexpected result {result} or kind {p._last_failure_kind}")
except Exception as e:
    bad(f"I: exception: {e}")
finally:
    mod.run_in_process_group = orig_run
    shutil.rmtree(tmp)

# Restore original functions
mod.select_frequency_combination = orig_select
mod.run_in_process_group = orig_run

print(f"RESULT: {PASS} passed, {FAIL} failed")
sys.exit(FAIL)
PYEOF

exit $?
