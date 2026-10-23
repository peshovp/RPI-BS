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

FREQ = {'frq': ['G12', 'R12', 'E17'], 'sys': 'GRE', 'fallback': False, 'bands': {}, 'reasons': {}}

class FakePride:
    def __init__(self, rtkbase_root=None, behaviour='ok'):
        self._behaviour = behaviour
        if behaviour == 'unavailable':
            raise ctrl_mod.Pdp3NotFoundError('x')
    def process_ppp_ar(self, obs_file, work_dir=None, custom_antex_path=None):
        self._last_freq_selection = FREQ
        if self._behaviour == 'fail':
            return None
        if self._behaviour == 'parse_fail':
            return Path('pos_file')
        return Path('pos_file')
    def parse_ppp_ar_result(self, pos_file):
        return None

def make_controller(tmp, raw_files, rinex_result, pdp3_behaviour):
    c = SC.__new__(SC)
    c.rtkbase = SimpleNamespace(
        rtkbase_root=tmp,
        get_data_files_since=lambda start_time, extract_dir=None, end_time=None: raw_files,
        get_receiver_info=lambda: {'model': 'ZED-F9P', 'firmware': '1.0'}
    )
    c.state = SimpleNamespace(
        get_status=lambda: {'start_time': '2026-10-01T00:00:00'}
    )
    c.work_dir = tmp
    c.rinex = SimpleNamespace(
        convert_raw_files_to_rinex_obs=lambda *a, **kw: rinex_result
    )
    c.spp = SimpleNamespace(
        resolve_augmented_custom_antex=lambda: None
    )
    c._resolve_antenna_calibration = lambda: {'antenna_type': 'X', 'antenna_calibrated': False}
    c._cleanup_old_ppp_ar_slot_dirs = lambda *a, **k: None
    return c

with tempfile.TemporaryDirectory() as tmpdir:
    tmp = Path(tmpdir)

    # Case A: run method stores context on pdp3_failed
    try:
        c = make_controller(tmp, [Path('a.ubx')], (Path('a.obs'), None), 'fail')
        orig_extract = ctrl_mod.extract_observation_duration_minutes
        orig_pride = ctrl_mod.PridePpparProcessor
        ctrl_mod.extract_observation_duration_minutes = lambda f: 480.0
        ctrl_mod.PridePpparProcessor = lambda *a, **k: FakePride(*a, behaviour='fail', **k)
        try:
            result = c._run_ppp_ar(slot_label='4h')
            if result is None:
                ok("A: run returns None on pdp3_failed")
            else:
                bad(f"A: expected None, got {result}")
            ctx = c._last_ppp_ar_run_context
            if ctx['stage'] == 'pdp3_failed':
                ok("A: stage is pdp3_failed")
            else:
                bad(f"A: stage is {ctx['stage']}, expected pdp3_failed")
            if ctx['frequency_selection']['frq'] == ['G12', 'R12', 'E17']:
                ok("A: frequency_selection frq correct")
            else:
                bad(f"A: frequency_selection frq is {ctx['frequency_selection']['frq']}")
            if ctx['obs_duration_minutes'] == 480.0:
                ok("A: obs_duration_minutes is 480.0")
            else:
                bad(f"A: obs_duration_minutes is {ctx['obs_duration_minutes']}")
        finally:
            ctrl_mod.extract_observation_duration_minutes = orig_extract
            ctrl_mod.PridePpparProcessor = orig_pride
    except Exception as e:
        bad(f"A: exception: {e}")

    # Case B: builder copies context into record
    try:
        c = make_controller(tmp, [Path('a.ubx')], (Path('a.obs'), None), 'fail')
        orig_extract = ctrl_mod.extract_observation_duration_minutes
        orig_pride = ctrl_mod.PridePpparProcessor
        ctrl_mod.extract_observation_duration_minutes = lambda f: 480.0
        ctrl_mod.PridePpparProcessor = lambda *a, **k: FakePride(*a, behaviour='fail', **k)
        try:
            c._run_ppp_ar(slot_label='4h')
            rec = c._build_ppp_ar_attempt_record('4h', 'FAILED', 'x', None)
            if rec['frequency_selection']['frq'] == ['G12', 'R12', 'E17']:
                ok("B: record frequency_selection frq correct")
            else:
                bad(f"B: record frequency_selection frq is {rec['frequency_selection']['frq']}")
            if rec['obs_duration_minutes'] == 480.0:
                ok("B: record obs_duration_minutes is 480.0")
            else:
                bad(f"B: record obs_duration_minutes is {rec['obs_duration_minutes']}")
            if rec['failure_stage'] == 'pdp3_failed':
                ok("B: record failure_stage is pdp3_failed")
            else:
                bad(f"B: record failure_stage is {rec['failure_stage']}")
        finally:
            ctrl_mod.extract_observation_duration_minutes = orig_extract
            ctrl_mod.PridePpparProcessor = orig_pride
    except Exception as e:
        bad(f"B: exception: {e}")

    # Case C: pdp3_unavailable
    try:
        c = make_controller(tmp, [Path('a.ubx')], (Path('a.obs'), None), 'unavailable')
        orig_pride = ctrl_mod.PridePpparProcessor
        ctrl_mod.PridePpparProcessor = lambda *a, **k: FakePride(*a, behaviour='unavailable', **k)
        try:
            result = c._run_ppp_ar(slot_label='4h')
            if result is None:
                ok("C: run returns None on pdp3_unavailable")
            else:
                bad(f"C: expected None, got {result}")
            if c._last_ppp_ar_run_context['stage'] == 'pdp3_unavailable':
                ok("C: stage is pdp3_unavailable")
            else:
                bad(f"C: stage is {c._last_ppp_ar_run_context['stage']}")
            if c._last_ppp_ar_run_context['frequency_selection'] is None:
                ok("C: frequency_selection is None")
            else:
                bad(f"C: frequency_selection is {c._last_ppp_ar_run_context['frequency_selection']}")
        finally:
            ctrl_mod.PridePpparProcessor = orig_pride
    except Exception as e:
        bad(f"C: exception: {e}")

    # Case D: no_raw_data
    try:
        c = make_controller(tmp, [], (Path('a.obs'), None), 'ok')
        orig_pride = ctrl_mod.PridePpparProcessor
        ctrl_mod.PridePpparProcessor = lambda *a, **k: FakePride(*a, behaviour='fail', **k)
        try:
            result = c._run_ppp_ar(slot_label='4h')
            if result is None:
                ok("D: run returns None on no_raw_data")
            else:
                bad(f"D: expected None, got {result}")
            if c._last_ppp_ar_run_context['stage'] == 'no_raw_data':
                ok("D: stage is no_raw_data")
            else:
                bad(f"D: stage is {c._last_ppp_ar_run_context['stage']}")
        finally:
            ctrl_mod.PridePpparProcessor = orig_pride
    except Exception as e:
        bad(f"D: exception: {e}")

    # Case E: rinex_conversion_failed
    try:
        c = make_controller(tmp, [Path('a.ubx')], None, 'ok')
        orig_pride = ctrl_mod.PridePpparProcessor
        ctrl_mod.PridePpparProcessor = lambda *a, **k: FakePride(*a, behaviour='fail', **k)
        try:
            result = c._run_ppp_ar(slot_label='4h')
            if result is None:
                ok("E: run returns None on rinex_conversion_failed")
            else:
                bad(f"E: expected None, got {result}")
            if c._last_ppp_ar_run_context['stage'] == 'rinex_conversion_failed':
                ok("E: stage is rinex_conversion_failed")
            else:
                bad(f"E: stage is {c._last_ppp_ar_run_context['stage']}")
        finally:
            ctrl_mod.PridePpparProcessor = orig_pride
    except Exception as e:
        bad(f"E: exception: {e}")

    # Case F: parse_failed
    try:
        c = make_controller(tmp, [Path('a.ubx')], (Path('a.obs'), None), 'parse_fail')
        orig_pride = ctrl_mod.PridePpparProcessor
        ctrl_mod.PridePpparProcessor = lambda *a, **k: FakePride(*a, behaviour='parse_fail', **k)
        try:
            result = c._run_ppp_ar(slot_label='4h')
            if result is None:
                ok("F: run returns None on parse_failed")
            else:
                bad(f"F: expected None, got {result}")
            if c._last_ppp_ar_run_context['stage'] == 'parse_failed':
                ok("F: stage is parse_failed")
            else:
                bad(f"F: stage is {c._last_ppp_ar_run_context['stage']}")
            if c._last_ppp_ar_run_context['frequency_selection']['frq'] == ['G12', 'R12', 'E17']:
                ok("F: frequency_selection frq correct")
            else:
                bad(f"F: frequency_selection frq is {c._last_ppp_ar_run_context['frequency_selection']['frq']}")
        finally:
            ctrl_mod.PridePpparProcessor = orig_pride
    except Exception as e:
        bad(f"F: exception: {e}")

    # Case G: builder without context attribute
    try:
        c = SC.__new__(SC)
        rec = c._build_ppp_ar_attempt_record('0h', 'FAILED', 'x', None)
        if rec['frequency_selection'] is None:
            ok("G: frequency_selection is None without context")
        else:
            bad(f"G: frequency_selection is {rec['frequency_selection']}")
        if rec['obs_duration_minutes'] is None:
            ok("G: obs_duration_minutes is None without context")
        else:
            bad(f"G: obs_duration_minutes is {rec['obs_duration_minutes']}")
        if rec['failure_stage'] is None:
            ok("G: failure_stage is None without context")
        else:
            bad(f"G: failure_stage is {rec['failure_stage']}")
    except Exception as e:
        bad(f"G: exception: {e}")

    # Case H: builder with result dict
    try:
        c = SC.__new__(SC)
        result_dict = {'obs_duration_minutes': 10.0, 'frequency_selection': FREQ}
        rec = c._build_ppp_ar_attempt_record('0h', 'SUCCESS', 'x', result_dict)
        if rec['frequency_selection'] is FREQ:
            ok("H: frequency_selection is the result dict's value")
        else:
            bad(f"H: frequency_selection is {rec['frequency_selection']}")
        if rec['failure_stage'] is None:
            ok("H: failure_stage is None with result")
        else:
            bad(f"H: failure_stage is {rec['failure_stage']}")
    except Exception as e:
        bad(f"H: exception: {e}")

print(f"RESULT: {PASS} passed, {FAIL} failed")
sys.exit(FAIL)
PYEOF

exit $?
