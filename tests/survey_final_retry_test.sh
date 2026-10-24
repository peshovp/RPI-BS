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
import importlib
import importlib.util
import importlib.abc
import importlib.machinery
from pathlib import Path
from types import SimpleNamespace
import unittest.mock
import threading
import time
import inspect
from datetime import datetime, timedelta

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

class FakeState:
    def __init__(self):
        self.calls = []
        self.status_dict = {}
        self.survey_state = None
        self.reasons = []

    def get_status(self):
        return dict(self.status_dict)

    def record_heartbeat(self, n):
        self.calls.append('hb')

    def record_final_attempt(self, attempt, reason, nxt):
        self.calls.append(('final_attempt', attempt))
        self.reasons.append(reason)

    def clear_final_attempts(self):
        self.calls.append('clear')

    def complete_survey(self, pos):
        self.calls.append('complete')

    def mark_applied(self, pos):
        self.calls.append('mark_applied')

    def begin_finalizing(self):
        self.calls.append('begin_finalizing')
        if self.survey_state == ctrl_mod.SurveyState.RUNNING:
            self.survey_state = ctrl_mod.SurveyState.FINALIZING
            return True
        return self.survey_state == ctrl_mod.SurveyState.FINALIZING

def make_final(ppp_ar_enabled=True):
    c = SC.__new__(SC)
    c.ppp_ar_enabled = ppp_ar_enabled
    c.target_hours = 24
    c.auto_mode = True
    c._running = True
    c.recovery_pending = False
    c._services_restarted = False
    c._last_ppp_ar_attempt_summary = 'PPP-AR ATTEMPT slot=final result=FAILED reason=test'

    c.state = FakeState()
    c.state.survey_state = ctrl_mod.SurveyState.RUNNING
    c.state.status_dict = {
        'start_time': '2026-10-20T00:00:00',
        'current_position': None,
        'position_std': {},
        'num_epochs': 1
    }

    c.rtkbase = SimpleNamespace(update_position=lambda lat, lon, h: True)
    c.restart_rtkbase_services = lambda: {'success': True}

    stops = []
    fails = []
    delays = []
    updates = []
    windows = []
    results = []

    c._stop_file_logging = lambda reason=None: stops.append(reason)
    c._fail = lambda reason: fails.append(reason)
    c._wait_while_running = lambda s: delays.append(s)
    c._perform_update = lambda is_final=False: updates.append(is_final)

    def fake_attempt(window_end):
        windows.append(window_end)
        c.state.calls.append('attempt')
        if results:
            r = results.pop(0)
            if r:
                c.state.status_dict['current_position'] = {'lat': 42.0, 'lon': 24.0, 'height': 500.0}
            return r
        return False

    c._attempt_final_ppp_ar = fake_attempt
    c._final_products_status = lambda start, end: {'available': True, 'missing': [], 'error': None}

    return c, stops, fails, delays, updates, windows, results

# Case A: retry succeeds on 3rd attempt
try:
    c, stops, fails, delays, updates, windows, results = make_final(True)
    results.extend([False, False, True])

    orig_sleep = ctrl_mod.time.sleep
    orig_announce = ctrl_mod._announce_planned_disconnect
    orig_log = ctrl_mod.log_event
    ctrl_mod.time.sleep = lambda s: None
    ctrl_mod._announce_planned_disconnect = lambda *a, **k: None
    ctrl_mod.log_event = lambda *a, **k: None

    try:
        c._finalize_survey()
        if len(windows) == 3:
            ok("A: _attempt_final_ppp_ar called 3 times")
        else:
            bad(f"A: _attempt_final_ppp_ar called {len(windows)} times, expected 3")
        if delays == [600, 600]:
            ok("A: delays are [600, 600]")
        else:
            bad(f"A: delays are {delays}, expected [600, 600]")
        attempt_calls = [x for x in c.state.calls if isinstance(x, tuple) and x[0] == 'final_attempt']
        if len(attempt_calls) == 2 and attempt_calls[0][1] == 1 and attempt_calls[1][1] == 2:
            ok("A: record_final_attempt called for attempts 1 and 2")
        else:
            bad(f"A: record_final_attempt calls: {attempt_calls}")
        if 'clear' in c.state.calls:
            ok("A: clear_final_attempts called")
        else:
            bad("A: clear_final_attempts not called")
        if 'complete' in c.state.calls:
            ok("A: complete_survey called")
        else:
            bad("A: complete_survey not called")
        if fails == []:
            ok("A: no failures recorded")
        else:
            bad(f"A: failures recorded: {fails}")
        expected_window = datetime(2026, 10, 21, 0, 0, 0)
        if all(w == expected_window for w in windows):
            ok("A: all windows equal datetime(2026, 10, 21, 0, 0, 0)")
        else:
            bad(f"A: windows are {windows}")
        if stops == ['data_collection_complete', 'survey_completed']:
            ok("A: _stop_file_logging called with 'data_collection_complete' then 'survey_completed'")
        else:
            bad(f"A: stops are {stops}")
        if 'begin_finalizing' in c.state.calls:
            bi = c.state.calls.index('begin_finalizing')
            ai = c.state.calls.index('attempt')
            if bi < ai:
                ok("A: begin_finalizing called before first attempt")
            else:
                bad(f"A: begin_finalizing at {bi}, first attempt at {ai}")
        else:
            bad("A: begin_finalizing not called")
    finally:
        ctrl_mod.time.sleep = orig_sleep
        ctrl_mod._announce_planned_disconnect = orig_announce
        ctrl_mod.log_event = orig_log
except Exception as e:
    bad(f"A: exception: {e}")

# Case B: retry succeeds on 8th attempt (after backoff increase)
try:
    c, stops, fails, delays, updates, windows, results = make_final(True)
    results.extend([False]*7 + [True])

    orig_sleep = ctrl_mod.time.sleep
    orig_announce = ctrl_mod._announce_planned_disconnect
    orig_log = ctrl_mod.log_event
    ctrl_mod.time.sleep = lambda s: None
    ctrl_mod._announce_planned_disconnect = lambda *a, **k: None
    ctrl_mod.log_event = lambda *a, **k: None

    try:
        c._finalize_survey()
        expected_delays = [600]*5 + [3600]*2
        if delays == expected_delays:
            ok("B: delays are [600]*5 + [3600]*2")
        else:
            bad(f"B: delays are {delays}, expected {expected_delays}")
    finally:
        ctrl_mod.time.sleep = orig_sleep
        ctrl_mod._announce_planned_disconnect = orig_announce
        ctrl_mod.log_event = orig_log
except Exception as e:
    bad(f"B: exception: {e}")

# Case C: stopped while waiting - only 1 attempt, no completion
try:
    c, stops, fails, delays, updates, windows, results = make_final(True)
    results.extend([False, False, False])

    orig_wait = c._wait_while_running
    def wait_and_stop(s):
        delays.append(s)
        c._running = False
    c._wait_while_running = wait_and_stop

    orig_sleep = ctrl_mod.time.sleep
    orig_announce = ctrl_mod._announce_planned_disconnect
    orig_log = ctrl_mod.log_event
    ctrl_mod.time.sleep = lambda s: None
    ctrl_mod._announce_planned_disconnect = lambda *a, **k: None
    ctrl_mod.log_event = lambda *a, **k: None

    try:
        c._finalize_survey()
        if len(windows) == 1:
            ok("C: exactly 1 attempt made")
        else:
            bad(f"C: {len(windows)} attempts made, expected 1")
        if 'complete' not in c.state.calls:
            ok("C: complete_survey not called")
        else:
            bad("C: complete_survey called")
        if fails == []:
            ok("C: no failures recorded")
        else:
            bad(f"C: failures recorded: {fails}")
        if stops == ['data_collection_complete']:
            ok("C: _stop_file_logging called with 'data_collection_complete'")
        else:
            bad(f"C: stops are {stops}")
    finally:
        c._wait_while_running = orig_wait
        ctrl_mod.time.sleep = orig_sleep
        ctrl_mod._announce_planned_disconnect = orig_announce
        ctrl_mod.log_event = orig_log
except Exception as e:
    bad(f"C: exception: {e}")

# Case D: state paused before first attempt - zero attempts
try:
    c, stops, fails, delays, updates, windows, results = make_final(True)
    c.state.survey_state = ctrl_mod.SurveyState.PAUSED
    results.extend([False, False, False])

    orig_sleep = ctrl_mod.time.sleep
    orig_announce = ctrl_mod._announce_planned_disconnect
    orig_log = ctrl_mod.log_event
    ctrl_mod.time.sleep = lambda s: None
    ctrl_mod._announce_planned_disconnect = lambda *a, **k: None
    ctrl_mod.log_event = lambda *a, **k: None

    try:
        c._finalize_survey()
        if len(windows) == 0:
            ok("D: zero attempts made")
        else:
            bad(f"D: {len(windows)} attempts made, expected 0")
        if 'complete' not in c.state.calls:
            ok("D: complete_survey not called")
        else:
            bad("D: complete_survey called")
        if fails == []:
            ok("D: no failures recorded")
        else:
            bad(f"D: failures recorded: {fails}")
    finally:
        ctrl_mod.time.sleep = orig_sleep
        ctrl_mod._announce_planned_disconnect = orig_announce
        ctrl_mod.log_event = orig_log
except Exception as e:
    bad(f"D: exception: {e}")

# Case E: _final_retry_delay_seconds returns correct values
try:
    c, stops, fails, delays, updates, windows, results = make_final(True)
    correct = True
    for n in range(1, 6):
        if c._final_retry_delay_seconds(n) != 600:
            correct = False
            break
    if correct and c._final_retry_delay_seconds(6) == 3600 and c._final_retry_delay_seconds(20) == 3600:
        ok("E: _final_retry_delay_seconds returns 600 for 1-5, 3600 for 6+")
    else:
        bad("E: _final_retry_delay_seconds returns incorrect values")
except Exception as e:
    bad(f"E: exception: {e}")

# Case F: ppp_ar_enabled False - no retry loop
try:
    c, stops, fails, delays, updates, windows, results = make_final(False)
    results.extend([False, False, True])

    orig_sleep = ctrl_mod.time.sleep
    orig_announce = ctrl_mod._announce_planned_disconnect
    orig_log = ctrl_mod.log_event
    ctrl_mod.time.sleep = lambda s: None
    ctrl_mod._announce_planned_disconnect = lambda *a, **k: None
    ctrl_mod.log_event = lambda *a, **k: None

    try:
        c._finalize_survey()
        if updates == [True]:
            ok("F: _perform_update(is_final=True) called exactly once")
        else:
            bad(f"F: updates are {updates}, expected [True]")
        if len(windows) == 0:
            ok("F: zero attempts made")
        else:
            bad(f"F: {len(windows)} attempts made, expected 0")
    finally:
        ctrl_mod.time.sleep = orig_sleep
        ctrl_mod._announce_planned_disconnect = orig_announce
        ctrl_mod.log_event = orig_log
except Exception as e:
    bad(f"F: exception: {e}")

# Case G: source check - _run_ppp_ar passes window_end
try:
    src = inspect.getsource(SC._run_ppp_ar)
    if 'end_time=window_end' in src and 'time_end=window_end' in src:
        ok("G: _run_ppp_ar source contains end_time=window_end and time_end=window_end")
    else:
        bad("G: _run_ppp_ar source missing window_end parameters")
except Exception as e:
    bad(f"G: exception: {e}")

# Case H: heartbeat recorded per attempt
try:
    c, stops, fails, delays, updates, windows, results = make_final(True)
    results.extend([False, False, True])

    orig_sleep = ctrl_mod.time.sleep
    orig_announce = ctrl_mod._announce_planned_disconnect
    orig_log = ctrl_mod.log_event
    ctrl_mod.time.sleep = lambda s: None
    ctrl_mod._announce_planned_disconnect = lambda *a, **k: None
    ctrl_mod.log_event = lambda *a, **k: None

    try:
        c._finalize_survey()
        hb_count = c.state.calls.count('hb')
        if hb_count >= 3:
            ok(f"H: heartbeat recorded {hb_count} times (>= 3)")
        else:
            bad(f"H: heartbeat recorded {hb_count} times, expected >= 3")
    finally:
        ctrl_mod.time.sleep = orig_sleep
        ctrl_mod._announce_planned_disconnect = orig_announce
        ctrl_mod.log_event = orig_log
except Exception as e:
    bad(f"H: exception: {e}")

# Case I: waiting for products
try:
    c, stops, fails, delays, updates, windows, results = make_final(True)
    call_count = [0]
    def products_waiting(start, end):
        call_count[0] += 1
        if call_count[0] <= 2:
            return {'available': False, 'missing': ['2026 DOY 297: ERP', '2026 DOY 297: orbit'], 'error': None}
        return {'available': True, 'missing': [], 'error': None}
    c._final_products_status = products_waiting
    results.extend([True])

    orig_sleep = ctrl_mod.time.sleep
    orig_announce = ctrl_mod._announce_planned_disconnect
    orig_log = ctrl_mod.log_event
    ctrl_mod.time.sleep = lambda s: None
    ctrl_mod._announce_planned_disconnect = lambda *a, **k: None
    ctrl_mod.log_event = lambda *a, **k: None

    try:
        c._finalize_survey()
        if len(windows) == 1:
            ok("I: exactly 1 real attempt made")
        else:
            bad(f"I: {len(windows)} real attempts made, expected 1")
        if delays == [600, 600]:
            ok("I: delays are [600, 600]")
        else:
            bad(f"I: delays are {delays}, expected [600, 600]")
        waiting_reasons = [r for r in c.state.reasons if 'waiting for precise products' in r and '2026 DOY 297' in r]
        if len(waiting_reasons) == 2:
            ok("I: two record_final_attempt entries with waiting reasons")
        else:
            bad(f"I: {len(waiting_reasons)} waiting reasons, expected 2")
        if 'complete' in c.state.calls:
            ok("I: complete_survey called")
        else:
            bad("I: complete_survey not called")
    finally:
        ctrl_mod.time.sleep = orig_sleep
        ctrl_mod._announce_planned_disconnect = orig_announce
        ctrl_mod.log_event = orig_log
except Exception as e:
    bad(f"I: exception: {e}")

# Case J: blind attempt
try:
    c, stops, fails, delays, updates, windows, results = make_final(True)
    c._final_products_status = lambda start, end: {'available': False, 'missing': ['x'], 'error': None}
    results.extend([True])

    monotonic_calls = [0]
    def fake_monotonic():
        monotonic_calls[0] += 1
        if monotonic_calls[0] == 1:
            return 0.0
        return (monotonic_calls[0] - 1) * 7 * 3600
    orig_monotonic = ctrl_mod.time.monotonic
    ctrl_mod.time.monotonic = fake_monotonic

    orig_sleep = ctrl_mod.time.sleep
    orig_announce = ctrl_mod._announce_planned_disconnect
    orig_log = ctrl_mod.log_event
    ctrl_mod.time.sleep = lambda s: None
    ctrl_mod._announce_planned_disconnect = lambda *a, **k: None
    ctrl_mod.log_event = lambda *a, **k: None

    try:
        c._finalize_survey()
        if len(windows) == 1:
            ok("J: exactly 1 real attempt made (blind attempt due)")
        else:
            bad(f"J: {len(windows)} real attempts made, expected 1")
        if 'complete' in c.state.calls:
            ok("J: complete_survey called")
        else:
            bad("J: complete_survey not called")
    finally:
        ctrl_mod.time.monotonic = orig_monotonic
        ctrl_mod.time.sleep = orig_sleep
        ctrl_mod._announce_planned_disconnect = orig_announce
        ctrl_mod.log_event = orig_log
except Exception as e:
    bad(f"J: exception: {e}")

# Case K: unknown availability proceeds
try:
    c, stops, fails, delays, updates, windows, results = make_final(True)
    c._final_products_status = lambda start, end: {'available': None, 'missing': [], 'error': 'OSError: no route'}
    results.extend([True])

    orig_sleep = ctrl_mod.time.sleep
    orig_announce = ctrl_mod._announce_planned_disconnect
    orig_log = ctrl_mod.log_event
    ctrl_mod.time.sleep = lambda s: None
    ctrl_mod._announce_planned_disconnect = lambda *a, **k: None
    ctrl_mod.log_event = lambda *a, **k: None

    try:
        c._finalize_survey()
        if len(windows) == 1:
            ok("K: exactly 1 real attempt made")
        else:
            bad(f"K: {len(windows)} real attempts made, expected 1")
        if delays == []:
            ok("K: no delays")
        else:
            bad(f"K: delays are {delays}, expected []")
    finally:
        ctrl_mod.time.sleep = orig_sleep
        ctrl_mod._announce_planned_disconnect = orig_announce
        ctrl_mod.log_event = orig_log
except Exception as e:
    bad(f"K: exception: {e}")

# Case L: _compute_ppp_ar_slots returns []
try:
    for target in [6, 24]:
        c = SC.__new__(SC)
        c.target_hours = target
        slots = c._compute_ppp_ar_slots()
        if slots == []:
            ok(f"L: _compute_ppp_ar_slots returns [] for target_hours={target}")
        else:
            bad(f"L: _compute_ppp_ar_slots returns {slots} for target_hours={target}, expected []")
except Exception as e:
    bad(f"L: exception: {e}")

print(f"RESULT: {PASS} passed, {FAIL} failed")
sys.exit(FAIL)
PYEOF

exit $?
