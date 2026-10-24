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

REPO = sys.argv[1]

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

# Load the module
try:
    path = os.environ.get('GM_FAILURE_MODULE')
    if not path:
        path = os.path.join(REPO, 'addons', 'features', 'auto_survey', 'ppp_ar_failure.py')
    spec = importlib.util.spec_from_file_location('ppp_ar_failure', path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
except Exception as e:
    bad(f"module load: {e}")
    print(f"RESULT: {PASS} passed, {FAIL} failed")
    sys.exit(FAIL)

# Case A: describe_failure table
test_cases = [
    ('pdp3_unavailable', None, 'tool_missing'),
    ('no_raw_data', None, 'no_data'),
    ('rinex_conversion_failed', None, 'conversion'),
    ('parse_failed', None, 'parse'),
    ('fix_rate_below_threshold', None, 'fix_rate'),
    ('apply_failed', None, 'apply'),
    ('pdp3_failed', 'timeout', 'pdp3_timeout'),
    ('pdp3_failed', 'product_download', 'product'),
    ('pdp3_failed', 'nonzero_exit', 'pdp3_error'),
    ('pdp3_failed', 'no_pos_file', 'pdp3_error'),
    ('pdp3_failed', 'exception', 'pdp3_error'),
    ('pdp3_failed', None, 'pdp3_error'),
    ('pdp3_failed', 'something_else', 'pdp3_error'),
    (None, None, 'unknown'),
    ('bogus', 'timeout', 'unknown'),
]

for stage, kind, expected_class in test_cases:
    try:
        info = mod.describe_failure(stage, kind)
        if info['error_class'] == expected_class:
            ok(f"A: {stage}/{kind} -> {expected_class}")
        else:
            bad(f"A: {stage}/{kind} -> expected {expected_class}, got {info['error_class']}")
    except Exception as e:
        bad(f"A: {stage}/{kind} exception: {e}")

# Case B: dict structure
try:
    all_info = []
    for stage, kind, _ in test_cases:
        all_info.append(mod.describe_failure(stage, kind))
    
    b_ok = True
    for info in all_info:
        if set(info.keys()) != {'error_class', 'reason'}:
            bad(f"B: wrong keys: {set(info.keys())}")
            b_ok = False
            break
        if not isinstance(info['reason'], str) or len(info['reason']) == 0:
            bad(f"B: reason not non-empty string: {info['reason']}")
            b_ok = False
            break
        if info['reason'].endswith('.'):
            bad(f"B: reason has trailing period: {info['reason']}")
            b_ok = False
            break
    if b_ok:
        ok("B: all dicts have correct structure")
except Exception as e:
    bad(f"B: exception: {e}")

# Case C: reasons are distinct for different error classes
try:
    class_reasons = {}
    for info in all_info:
        ec = info['error_class']
        if ec not in class_reasons:
            class_reasons[ec] = info['reason']
    
    target_classes = ['tool_missing', 'no_data', 'conversion', 'parse', 'product', 'fix_rate', 'apply']
    target_reasons = [class_reasons.get(c, '') for c in target_classes]
    
    c_ok = True
    if len(set(target_reasons)) != len(target_reasons):
        bad("C: reasons are not distinct")
        c_ok = False
    if any('no result from' in r for r in target_reasons):
        bad("C: some reason contains 'no result from'")
        c_ok = False
    if c_ok:
        ok("C: reasons are distinct and don't contain 'no result from'")
except Exception as e:
    bad(f"C: exception: {e}")

# Case D: should_retry no longer exists
try:
    if hasattr(mod, 'should_retry'):
        bad("D: should_retry still exists")
    else:
        ok("D: should_retry removed")
except Exception as e:
    bad(f"D: exception: {e}")

print(f"RESULT: {PASS} passed, {FAIL} failed")
sys.exit(FAIL)
PYEOF

exit $?
