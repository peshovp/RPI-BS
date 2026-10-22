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
    ('pdp3_unavailable', None, 'tool_missing', 1),
    ('no_raw_data', None, 'no_data', 1),
    ('rinex_conversion_failed', None, 'conversion', 1),
    ('parse_failed', None, 'parse', 1),
    ('pdp3_failed', 'timeout', 'pdp3_timeout', 2),
    ('pdp3_failed', 'product_download', 'product', 5),
    ('pdp3_failed', 'nonzero_exit', 'pdp3_error', 2),
    ('pdp3_failed', 'no_pos_file', 'pdp3_error', 2),
    ('pdp3_failed', 'exception', 'pdp3_error', 2),
    ('pdp3_failed', None, 'pdp3_error', 2),
    ('pdp3_failed', 'something_else', 'pdp3_error', 2),
    ('fix_rate_below_threshold', None, 'fix_rate', 1),
    ('apply_failed', None, 'apply', 1),
    (None, None, 'unknown', 2),
    ('bogus', 'timeout', 'unknown', 2),
]

for stage, kind, expected_class, expected_max in test_cases:
    try:
        info = mod.describe_failure(stage, kind)
        if info['error_class'] == expected_class and info['max_attempts'] == expected_max:
            ok(f"A: {stage}/{kind} -> {expected_class}/{expected_max}")
        else:
            bad(f"A: {stage}/{kind} -> expected {expected_class}/{expected_max}, got {info['error_class']}/{info['max_attempts']}")
    except Exception as e:
        bad(f"A: {stage}/{kind} exception: {e}")

# Case B: dict structure
try:
    all_info = []
    for stage, kind, _, _ in test_cases:
        all_info.append(mod.describe_failure(stage, kind))
    
    b_ok = True
    for info in all_info:
        if set(info.keys()) != {'error_class', 'max_attempts', 'reason'}:
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
        if not isinstance(info['max_attempts'], int) or info['max_attempts'] < 1:
            bad(f"B: max_attempts not int >= 1: {info['max_attempts']}")
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
    
    target_classes = ['tool_missing', 'no_data', 'conversion', 'parse', 'product']
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

# Case D: should_retry
try:
    product_info = mod.describe_failure('pdp3_failed', 'product_download')
    conversion_info = mod.describe_failure('rinex_conversion_failed')
    timeout_info = mod.describe_failure('pdp3_failed', 'timeout')
    
    d_ok = True
    for attempt in range(1, 5):
        if not mod.should_retry(product_info, attempt):
            bad(f"D: product attempt {attempt} should retry")
            d_ok = False
    if mod.should_retry(product_info, 5):
        bad("D: product attempt 5 should not retry")
        d_ok = False
    
    if mod.should_retry(conversion_info, 1):
        bad("D: conversion attempt 1 should not retry")
        d_ok = False
    
    if not mod.should_retry(timeout_info, 1):
        bad("D: timeout attempt 1 should retry")
        d_ok = False
    if mod.should_retry(timeout_info, 2):
        bad("D: timeout attempt 2 should not retry")
        d_ok = False
    
    if d_ok:
        ok("D: should_retry works correctly")
except Exception as e:
    bad(f"D: exception: {e}")

# Case E: deterministic classes never retry
try:
    e_ok = True
    for ec in ['tool_missing', 'no_data', 'conversion', 'parse', 'fix_rate', 'apply']:
        info = None
        for stage, kind, expected_class, _ in test_cases:
            if expected_class == ec:
                info = mod.describe_failure(stage, kind)
                break
        if info and mod.should_retry(info, 1):
            bad(f"E: {ec} should never retry")
            e_ok = False
    if e_ok:
        ok("E: deterministic classes never retry")
except Exception as e:
    bad(f"E: exception: {e}")

print(f"RESULT: {PASS} passed, {FAIL} failed")
sys.exit(FAIL)
PYEOF

exit $?
