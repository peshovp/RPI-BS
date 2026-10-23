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
import threading
import time

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
        self.recoverable = False
        self.survey_state = None

    def reload(self):
        self.calls.append('reload')
        return True

    def get_status(self):
        return dict(self.status_dict)

    def mark_applied(self, pos):
        self.calls.append('mark_applied')

    def can_recover(self):
        return self.recoverable

    def record_resume(self):
        self.calls.append('record_resume')
        self.status_dict['resume_count'] = self.status_dict.get('resume_count', 0) + 1

    def pause_survey(self):
        self.calls.append('pause')
        return True

class FakeRtkbase:
    def __init__(self):
        self.position_updates = []
        self.config = SimpleNamespace(get=lambda section, key, fallback='': 'ubx')

    def update_position(self, lat, lon, height):
        self.position_updates.append((lat, lon, height))
        return True

def make(ctrl_state_dict, is_runner):
    c = SC.__new__(SC)
    c.is_runner = is_runner
    c.state = FakeState()
    c.state.status_dict = dict(ctrl_state_dict)
    c.rtkbase = FakeRtkbase()
    c._running = False
    c._resolve_antenna_calibration = lambda: {'antenna_type': 'X', 'antenna_calibrated': False}
    c.restart_rtkbase_services = lambda: None
    return c

# Case A: web side, completed survey - reload called, no auto-apply
try:
    c = make({'survey_state': 'completed', 'applied': False, 'final_position': {'lat': 42.0, 'lon': 24.0, 'height': 500.0}}, False)
    status = c.get_status()
    if 'reload' in c.state.calls:
        ok("A: reload called on web side")
    else:
        bad("A: reload not called on web side")
    if len(c.rtkbase.position_updates) == 0:
        ok("A: no update_position on web side")
    else:
        bad(f"A: update_position called {len(c.rtkbase.position_updates)} times on web side")
    if 'mark_applied' not in c.state.calls:
        ok("A: no mark_applied on web side")
    else:
        bad("A: mark_applied called on web side")
    if status['is_running'] is False:
        ok("A: is_running is False on web side")
    else:
        bad(f"A: is_running is {status['is_running']} on web side")
except Exception as e:
    bad(f"A: exception: {e}")

# Case B: web side, running survey
try:
    c = make({'survey_state': 'running'}, False)
    status = c.get_status()
    if 'reload' in c.state.calls:
        ok("B: reload called on web side running")
    else:
        bad("B: reload not called on web side running")
    if status['is_running'] is True:
        ok("B: is_running is True on web side running")
    else:
        bad(f"B: is_running is {status['is_running']} on web side running")
except Exception as e:
    bad(f"B: exception: {e}")

# Case C: runner side, completed survey - auto-apply
try:
    c = make({'survey_state': 'completed', 'applied': False, 'final_position': {'lat': 42.0, 'lon': 24.0, 'height': 500.0}}, True)
    status = c.get_status()
    if len(c.rtkbase.position_updates) == 1 and c.rtkbase.position_updates[0] == (42.0, 24.0, 500.0):
        ok("C: update_position called with correct coords on runner side")
    else:
        bad(f"C: update_position not called correctly on runner side: {c.rtkbase.position_updates}")
    if 'mark_applied' in c.state.calls:
        ok("C: mark_applied called on runner side")
    else:
        bad("C: mark_applied not called on runner side")
    if 'reload' not in c.state.calls:
        ok("C: reload not called on runner side")
    else:
        bad("C: reload called on runner side")
except Exception as e:
    bad(f"C: exception: {e}")

# Case C2: runner side, running survey - is_running from _running attribute
try:
    c = make({'survey_state': 'running'}, True)
    c._running = False
    status = c.get_status()
    if status['is_running'] is False:
        ok("C2: is_running is False when _running is False on runner side")
    else:
        bad(f"C2: is_running is {status['is_running']} when _running is False on runner side")
    c._running = True
    status = c.get_status()
    if status['is_running'] is True:
        ok("C2: is_running is True when _running is True on runner side")
    else:
        bad(f"C2: is_running is {status['is_running']} when _running is True on runner side")
except Exception as e:
    bad(f"C2: exception: {e}")

# Case D: recover_survey resumes
try:
    c = make({'survey_state': 'running', 'target_hours': 24, 'ppp_tier': 'rapid', 'ppp_ar_enabled': False, 'resume_count': 0}, True)
    c.state.recoverable = True
    c.state.survey_state = ctrl_mod.SurveyState.RUNNING

    order = []
    def fake_ensure():
        order.append('ensure')
        return True
    c._ensure_file_logging = fake_ensure

    def fake_loop():
        order.append('loop')
    c._survey_loop = fake_loop

    log_events = []
    def fake_log_event(source, event, details):
        log_events.append((source, event, details))
    orig_log_event = ctrl_mod.log_event
    ctrl_mod.log_event = fake_log_event

    orig_subprocess_run = ctrl_mod.subprocess.run
    class FakeCompletedProcess:
        def __init__(self):
            self.returncode = 0
    ctrl_mod.subprocess.run = lambda *args, **kwargs: FakeCompletedProcess()

    try:
        result = c.recover_survey()
        if result is True:
            ok("D: recover_survey returns True")
        else:
            bad(f"D: recover_survey returns {result}")
        if 'record_resume' in c.state.calls:
            ok("D: record_resume called")
        else:
            bad("D: record_resume not called")
        if c._thread is not None:
            c._thread.join(timeout=2)
        if order == ['ensure', 'loop']:
            ok("D: ensure_file_logging called before survey loop")
        else:
            bad(f"D: order is {order}, expected ['ensure', 'loop']")
        if len(log_events) == 1 and log_events[0][0] == 'auto_survey' and log_events[0][1] == 'recovered':
            details = log_events[0][2]
            if details.get('resumed_after_interruption') is True and details.get('resume_count') == 1:
                ok("D: log_event called with correct details")
            else:
                bad(f"D: log_event details incorrect: {details}")
        else:
            bad(f"D: log_event not called correctly: {log_events}")
    finally:
        ctrl_mod.log_event = orig_log_event
        ctrl_mod.subprocess.run = orig_subprocess_run
except Exception as e:
    bad(f"D: exception: {e}")

# Case E: nothing to recover
try:
    c = make({'survey_state': 'idle'}, True)
    c.state.recoverable = False
    order = []
    def fake_ensure():
        order.append('ensure')
        return True
    c._ensure_file_logging = fake_ensure
    result = c.recover_survey()
    if result is False:
        ok("E: recover_survey returns False when not recoverable")
    else:
        bad(f"E: recover_survey returns {result} when not recoverable")
    if 'ensure' not in order:
        ok("E: ensure_file_logging not called when not recoverable")
    else:
        bad("E: ensure_file_logging called when not recoverable")
    if 'record_resume' not in c.state.calls:
        ok("E: record_resume not called when not recoverable")
    else:
        bad("E: record_resume called when not recoverable")
except Exception as e:
    bad(f"E: exception: {e}")

# ---- Reconcile behaviour (runner keeps a healthy survey 'running' instead of failing it) ----
def make_recoverable(is_runner, survey_state, recoverable=True):
    c = make({'survey_state': survey_state.value, 'target_hours': 24, 'ppp_tier': 'rapid',
              'ppp_ar_enabled': False, 'resume_count': 0}, is_runner)
    c.state.recoverable = recoverable
    c.state.survey_state = survey_state
    c.recovery_pending = False  # normally set by __init__ (instances here skip the constructor)
    c.fails = []
    c._fail = lambda reason: c.fails.append(reason)
    c._ensure_file_logging = lambda: True
    c._survey_loop = lambda: None
    return c

class FakeCompleted:
    def __init__(self, rc):
        self.returncode = rc

def with_receiver(rc_holder):
    # fake subprocess.run: return code taken from rc_holder[0]
    return lambda *a, **k: FakeCompleted(rc_holder[0])

orig_run = ctrl_mod.subprocess.run
orig_log = ctrl_mod.log_event
ctrl_mod.log_event = lambda *a, **k: None
try:
    # Case F/G: runner mode, receiver not ready -> pending, not failed; then ready -> resumed
    try:
        rc = [3]
        ctrl_mod.subprocess.run = with_receiver(rc)
        c = make_recoverable(True, ctrl_mod.SurveyState.RUNNING)
        r1 = c.recover_survey()
        if r1 is False and c.recovery_pending is True and c.fails == []:
            ok("F: receiver not ready -> pending, survey NOT failed")
        else:
            bad(f"F: result={r1} pending={c.recovery_pending} fails={c.fails}")
        rc[0] = 0
        r2 = c.recover_survey()
        if c._thread is not None:
            c._thread.join(timeout=2)
        if r2 is True and c.recovery_pending is False:
            ok("G: receiver ready on retry -> resumed, pending cleared")
        else:
            bad(f"G: result={r2} pending={c.recovery_pending}")
    except Exception as e:
        bad(f"F/G: exception: {e}")

    # Case H: stale running survey (not recoverable) -> failed with a reason; paused is left alone
    try:
        ctrl_mod.subprocess.run = with_receiver([0])
        c = make_recoverable(True, ctrl_mod.SurveyState.RUNNING, recoverable=False)
        r = c.recover_survey()
        if r is False and len(c.fails) == 1 and 'cannot be resumed' in c.fails[0]:
            ok("H1: stale running survey is failed with a reason")
        else:
            bad(f"H1: result={r} fails={c.fails}")
        c = make_recoverable(True, ctrl_mod.SurveyState.PAUSED, recoverable=False)
        r = c.recover_survey()
        if r is False and c.fails == []:
            ok("H2: paused (user-stopped) survey is left alone")
        else:
            bad(f"H2: result={r} fails={c.fails}")
    except Exception as e:
        bad(f"H: exception: {e}")

    # Case I: web mode (not the runner), receiver not ready -> legacy behaviour (fail)
    try:
        ctrl_mod.subprocess.run = with_receiver([3])
        c = make_recoverable(False, ctrl_mod.SurveyState.RUNNING)
        r = c.recover_survey()
        if r is False and len(c.fails) == 1 and c.recovery_pending is False:
            ok("I: non-runner keeps the legacy fail on a not-ready receiver")
        else:
            bad(f"I: result={r} fails={c.fails} pending={c.recovery_pending}")
    except Exception as e:
        bad(f"I: exception: {e}")

    # Case J: stop while the resume is pending cancels it
    try:
        c = make({'survey_state': 'running'}, True)
        c._running = False
        c.recovery_pending = True
        r = c.stop_survey()
        if r is True and 'pause' in c.state.calls and c.recovery_pending is False:
            ok("J1: stop while resume pending -> paused, pending cleared")
        else:
            bad(f"J1: result={r} calls={c.state.calls} pending={c.recovery_pending}")
        c = make({'survey_state': 'idle'}, True)
        c._running = False
        c.recovery_pending = False
        r = c.stop_survey()
        if r is False and 'pause' not in c.state.calls:
            ok("J2: stop with nothing running -> False, state untouched")
        else:
            bad(f"J2: result={r} calls={c.state.calls}")
    except Exception as e:
        bad(f"J: exception: {e}")
finally:
    ctrl_mod.subprocess.run = orig_run
    ctrl_mod.log_event = orig_log

print(f"RESULT: {PASS} passed, {FAIL} failed")
sys.exit(FAIL)
PYEOF

exit $?
