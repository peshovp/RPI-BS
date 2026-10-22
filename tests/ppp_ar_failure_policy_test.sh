#!/usr/bin/env bash
set -uo pipefail

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
if [ -n "${GM_REPO_ROOT:-}" ]; then
    REPO="$GM_REPO_ROOT"
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not available"
    exit 0
fi

python3 - "$REPO" <<'PYEOF'
import sys
import os
import tempfile
import importlib
import importlib.util
import importlib.abc
import importlib.machinery
from pathlib import Path
from types import SimpleNamespace
import unittest.mock

REPO = sys.argv[1]
sys.path.insert(0, REPO)

# Stub numpy, scipy, pyproj (not installed on test machine)
class Stub(importlib.abc.MetaPathFinder, importlib.abc.Loader):
    def find_spec(self, name, path=None, target=None):
        if name.split('.')[0] in ('numpy', 'scipy', 'pyproj'):
            return importlib.machinery.ModuleSpec(name, self, is_package=True)
        return None
    def create_module(self, spec):
        m = unittest.mock.MagicMock()
        m.__path__ = []
        m.__name__ = spec.name
        m.__spec__ = spec
        return m
    def exec_module(self, module):
        pass

sys.meta_path.append(Stub())

ctrl_mod = importlib.import_module('addons.features.auto_survey.survey_controller')
SC = ctrl_mod.SurveyController

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

def make_controller(run_result, ctx, fix_rate_ok=True, apply_ok=True):
    c = SC.__new__(SC)
    attempts = []
    failures = []
    c.state = SimpleNamespace(
        record_ppp_ar_attempt=lambda rec: attempts.append(rec),
        record_update_failure=lambda text: failures.append(text),
        get_status=lambda: {}
    )
    c._run_ppp_ar = lambda slot_label=None: run_result
    c._last_ppp_ar_run_context = ctx
    c._ppp_ar_fix_rate_ok = lambda r: fix_rate_ok
    c._apply_geodetic_position = lambda **kw: apply_ok
    c._ppp_ar_extra_position_fields = lambda r: {}
    c.ppp_tier = 'rapid'
    c._last_ppp_ar_attempt_summary = None
    c._last_ppp_ar_failure_info = None
    return (c, attempts, failures)

SUCCESS_RESULT = {
    'lat': 42.0, 'lon': 24.0, 'height': 500.0,
    'obs_file': 'x.obs',
    'wl_fix_rate': 95.0, 'nl_fix_rate': 95.0,
    'sig0': 0.001, 'nobs': 100,
    'obs_duration_minutes': 480.0,
    'frequency_selection': None
}

# Case A: pdp3_failed with product_download -> error_class 'product', max_attempts 5
try:
    c, attempts, failures = make_controller(None, {'stage': 'pdp3_failed', 'failure_kind': 'product_download'})
    result = c._run_ppp_ar_interim(4.0, 4)
    if result is False:
        ok("A: returns False on product download failure")
    else:
        bad(f"A: expected False, got {result}")
    if len(attempts) == 1 and attempts[0]['error_class'] == 'product':
        ok("A: attempt record has error_class 'product'")
    else:
        bad(f"A: attempt record error_class is {attempts[0]['error_class'] if attempts else 'missing'}")
    if len(failures) == 1 and 'precise products' in failures[0] and 'PPP-AR slot=' in failures[0] and 'no result from' not in failures[0]:
        ok("A: failure text mentions precise products and slot")
    else:
        bad(f"A: failure text is {failures[0] if failures else 'missing'}")
    if c._last_ppp_ar_failure_info['max_attempts'] == 5:
        ok("A: max_attempts is 5 for product failure")
    else:
        bad(f"A: max_attempts is {c._last_ppp_ar_failure_info['max_attempts']}")
except Exception as e:
    bad(f"A: exception: {e}")

# Case B: rinex_conversion_failed -> error_class 'conversion', max_attempts 1
try:
    c, attempts, failures = make_controller(None, {'stage': 'rinex_conversion_failed', 'failure_kind': None})
    result = c._run_ppp_ar_interim(4.0, 4)
    if result is False:
        ok("B: returns False on conversion failure")
    else:
        bad(f"B: expected False, got {result}")
    if len(attempts) == 1 and attempts[0]['error_class'] == 'conversion':
        ok("B: attempt record has error_class 'conversion'")
    else:
        bad(f"B: attempt record error_class is {attempts[0]['error_class'] if attempts else 'missing'}")
    if c._last_ppp_ar_failure_info['max_attempts'] == 1:
        ok("B: max_attempts is 1 for conversion failure")
    else:
        bad(f"B: max_attempts is {c._last_ppp_ar_failure_info['max_attempts']}")
    if len(failures) == 1:
        ok("B: one failure recorded")
    else:
        bad(f"B: {len(failures)} failures recorded")
except Exception as e:
    bad(f"B: exception: {e}")

# Case C: pdp3_failed with timeout -> error_class 'pdp3_timeout', max_attempts 2
try:
    c, attempts, failures = make_controller(None, {'stage': 'pdp3_failed', 'failure_kind': 'timeout'})
    result = c._run_ppp_ar_interim(4.0, 4)
    if result is False:
        ok("C: returns False on pdp3 timeout")
    else:
        bad(f"C: expected False, got {result}")
    if len(attempts) == 1 and attempts[0]['error_class'] == 'pdp3_timeout':
        ok("C: attempt record has error_class 'pdp3_timeout'")
    else:
        bad(f"C: attempt record error_class is {attempts[0]['error_class'] if attempts else 'missing'}")
    if c._last_ppp_ar_failure_info['max_attempts'] == 2:
        ok("C: max_attempts is 2 for pdp3 timeout")
    else:
        bad(f"C: max_attempts is {c._last_ppp_ar_failure_info['max_attempts']}")
except Exception as e:
    bad(f"C: exception: {e}")

# Case D: fix rate not ok -> error_class 'fix_rate', max_attempts 1
try:
    c, attempts, failures = make_controller(SUCCESS_RESULT, {'stage': 'completed', 'failure_kind': None}, fix_rate_ok=False)
    result = c._run_ppp_ar_interim(4.0, 4)
    if result is False:
        ok("D: returns False on fix rate failure")
    else:
        bad(f"D: expected False, got {result}")
    if len(attempts) == 1 and attempts[0]['error_class'] == 'fix_rate':
        ok("D: attempt record has error_class 'fix_rate'")
    else:
        bad(f"D: attempt record error_class is {attempts[0]['error_class'] if attempts else 'missing'}")
    if c._last_ppp_ar_failure_info['max_attempts'] == 1:
        ok("D: max_attempts is 1 for fix rate failure")
    else:
        bad(f"D: max_attempts is {c._last_ppp_ar_failure_info['max_attempts']}")
    if len(failures) == 1 and 'WL=95.0' in failures[0]:
        ok("D: failure text mentions WL fix rate")
    else:
        bad(f"D: failure text is {failures[0] if failures else 'missing'}")
except Exception as e:
    bad(f"D: exception: {e}")

# Case E: apply fails -> error_class 'apply'
try:
    c, attempts, failures = make_controller(SUCCESS_RESULT, {'stage': 'completed', 'failure_kind': None}, fix_rate_ok=True, apply_ok=False)
    result = c._run_ppp_ar_interim(4.0, 4)
    if result is False:
        ok("E: returns False on apply failure")
    else:
        bad(f"E: expected False, got {result}")
    if len(attempts) == 1 and attempts[0]['error_class'] == 'apply':
        ok("E: attempt record has error_class 'apply'")
    else:
        bad(f"E: attempt record error_class is {attempts[0]['error_class'] if attempts else 'missing'}")
    if len(failures) == 1:
        ok("E: one failure recorded")
    else:
        bad(f"E: {len(failures)} failures recorded")
except Exception as e:
    bad(f"E: exception: {e}")

# Case F: success -> returns True, no failures, error_class None
try:
    c, attempts, failures = make_controller(SUCCESS_RESULT, {'stage': 'completed', 'failure_kind': None}, fix_rate_ok=True, apply_ok=True)
    result = c._run_ppp_ar_interim(4.0, 4)
    if result is True:
        ok("F: returns True on success")
    else:
        bad(f"F: expected True, got {result}")
    if len(failures) == 0:
        ok("F: no failures recorded")
    else:
        bad(f"F: {len(failures)} failures recorded")
    if len(attempts) == 1 and attempts[0]['error_class'] is None:
        ok("F: attempt record has error_class None")
    else:
        bad(f"F: attempt record error_class is {attempts[0]['error_class'] if attempts else 'missing'}")
except Exception as e:
    bad(f"F: exception: {e}")

# Case G: failure_kind only matters for pdp3_failed
try:
    c, attempts, failures = make_controller(None, {'stage': 'no_raw_data', 'failure_kind': 'timeout'})
    result = c._run_ppp_ar_interim(4.0, 4)
    if result is False:
        ok("G: returns False on no_raw_data")
    else:
        bad(f"G: expected False, got {result}")
    if len(attempts) == 1 and attempts[0]['error_class'] == 'no_data':
        ok("G: attempt record has error_class 'no_data' (not timeout)")
    else:
        bad(f"G: attempt record error_class is {attempts[0]['error_class'] if attempts else 'missing'}")
except Exception as e:
    bad(f"G: exception: {e}")

# Case H: source check for retry loop
try:
    src_path = Path(REPO) / 'addons' / 'features' / 'auto_survey' / ('survey_controller' + '.py')
    src = src_path.read_text()
    if 'should_retry(failure_info, attempt_num)' in src:
        ok("H: source contains should_retry call")
    else:
        bad("H: source missing should_retry call")
    if 'self._last_ppp_ar_failure_info = None' in src:
        ok("H: source resets _last_ppp_ar_failure_info")
    else:
        bad("H: source missing _last_ppp_ar_failure_info reset")
except Exception as e:
    bad(f"H: exception: {e}")

print(f"RESULT: {PASS} passed, {FAIL} failed")
sys.exit(FAIL)
PYEOF

exit $?
