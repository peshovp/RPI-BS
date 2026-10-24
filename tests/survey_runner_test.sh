#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${GM_REPO_ROOT:-$(dirname "$SCRIPT_DIR")}"

if ! command -v python3 &>/dev/null; then
    echo "SKIP: python3 not found"
    exit 0
fi

FAIL=0
python3 - "$REPO" <<'PYEOF' || FAIL=$?
import importlib.util
import os
import sys
import tempfile
import time
import threading

REPO = sys.argv[1]

passed = 0
failed = 0

def check(name, condition):
    global passed, failed
    if condition:
        passed += 1
        print(f"PASS: {name}")
    else:
        failed += 1
        print(f"FAIL: {name}")

module_dir = os.path.join(REPO, 'addons', 'features', 'auto_survey')
module_name = 'survey_runner'
module_path = os.path.join(module_dir, module_name + '.py')

try:
    spec = importlib.util.spec_from_file_location(module_name, module_path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    check("module loads", True)
except Exception as e:
    check("module loads", False)
    print(f"  Error: {e}")
    print(f"RESULT: {passed} passed, {failed} failed")
    sys.exit(failed)

survey_requests = mod.survey_requests

class FakeState:
    def __init__(self):
        self.status_dict = {'survey_state': 'idle'}
    def get_status(self):
        return self.status_dict

class FakeController:
    def __init__(self):
        self.calls = []
        self.is_runner = False
        self.state = FakeState()
        self.recover_result = False
        self.recover_raises = False
        self.start_result = True
        self.stop_result = True
        self.recovery_pending = False
        self.recover_pending_after = None

    def recover_survey(self):
        self.calls.append('recover')
        if self.recover_pending_after is not None and self.calls.count('recover') >= self.recover_pending_after:
            self.recovery_pending = False
        if self.recover_raises:
            raise RuntimeError("recover failed")
        return self.recover_result

    def start_survey(self, target_hours):
        self.calls.append(('start', target_hours))
        return self.start_result

    def stop_survey(self):
        self.calls.append('stop')
        return self.stop_result

    def reset_survey(self):
        self.calls.append('reset')
        return True

    def get_status(self):
        self.calls.append('status')
        return {}

def make_runner(ctrl, req_dir, **kw):
    runner = mod.SurveyRunner(lambda: ctrl, request_dir=req_dir, **kw)
    runner.controller = ctrl
    return runner

with tempfile.TemporaryDirectory() as req_dir:
    # A. startup()
    ctrl = FakeController()
    runner = make_runner(ctrl, req_dir)
    result = runner.startup()
    check("A1: is_runner set", ctrl.is_runner)
    check("A2: recover called", 'recover' in ctrl.calls)
    check("A3: returns False on recover fail", result == False)

    ctrl2 = FakeController()
    ctrl2.recover_result = True
    runner2 = make_runner(ctrl2, req_dir)
    result2 = runner2.startup()
    check("A4: returns True on recover success", result2 == True)

    # B. startup() with recover_raises
    ctrl3 = FakeController()
    ctrl3.recover_raises = True
    runner3 = make_runner(ctrl3, req_dir)
    try:
        result3 = runner3.startup()
        check("B1: handles recover exception", result3 == False)
    except Exception:
        check("B1: handles recover exception", False)

    # C. recovery retry in run loop
    ctrl4 = FakeController()
    ctrl4.recovery_pending = True
    ctrl4.recover_pending_after = 3
    runner4 = make_runner(ctrl4, req_dir, poll_interval=0.02, status_interval=100, recover_retry_interval=0.05)
    stop_event = threading.Event()
    thread = threading.Thread(target=runner4.run, args=(stop_event,))
    thread.start()
    timeout = time.time() + 3
    while ctrl4.calls.count('recover') < 3 and time.time() < timeout:
        time.sleep(0.05)
    time.sleep(0.3)
    recover_count = ctrl4.calls.count('recover')
    check("C1: recovery retries 3 times", recover_count == 3)
    stop_event.set()
    thread.join(timeout=2)

    ctrl5 = FakeController()
    ctrl5.recovery_pending = False
    runner5 = make_runner(ctrl5, req_dir, poll_interval=0.02, status_interval=100, recover_retry_interval=0.05)
    stop_event2 = threading.Event()
    thread2 = threading.Thread(target=runner5.run, args=(stop_event2,))
    thread2.start()
    time.sleep(0.3)
    stop_event2.set()
    thread2.join(timeout=2)
    check("C2: no retry when not pending", ctrl5.calls.count('recover') == 1)

    # D. handle_request start
    ctrl6 = FakeController()
    runner6 = make_runner(ctrl6, req_dir)
    result6 = runner6.handle_request({'id': '1', 'action': 'start', 'params': {'target_hours': 48, 'ppp_tier': 'final', 'ppp_ar_enabled': True}})
    check("D1: start ok", result6['ok'])
    check("D2: start message", result6['message'] == 'started')
    start_calls = [c for c in ctrl6.calls if isinstance(c, tuple) and c[0] == 'start']
    check("D3: start params", len(start_calls) == 1 and start_calls[0] == ('start', 48))

    # E. invalid start params
    for params, desc in [
        ({'target_hours': 0}, 'target_hours 0'),
        ({'target_hours': 169}, 'target_hours 169'),
        ({'target_hours': 'x'}, 'target_hours x'),
        ({'target_hours': True}, 'target_hours True'),
    ]:
        ctrl = FakeController()
        runner = make_runner(ctrl, req_dir)
        result = runner.handle_request({'id': '1', 'action': 'start', 'params': params})
        start_calls = [c for c in ctrl.calls if isinstance(c, tuple) and c[0] == 'start']
        check(f"E: {desc}", not result['ok'] and len(start_calls) == 0)

    ctrl_extra = FakeController()
    runner_extra = make_runner(ctrl_extra, req_dir)
    result_extra = runner_extra.handle_request({'id': '1', 'action': 'start', 'params': {'target_hours': 24, 'ppp_tier': 'bogus', 'ppp_ar_enabled': 'yes'}})
    start_calls_extra = [c for c in ctrl_extra.calls if isinstance(c, tuple) and c[0] == 'start']
    check("E: extra keys ignored", result_extra['ok'] and len(start_calls_extra) == 1 and start_calls_extra[0] == ('start', 24))

    # F. start_result False
    ctrl7 = FakeController()
    ctrl7.start_result = False
    runner7 = make_runner(ctrl7, req_dir)
    result7 = runner7.handle_request({'id': '1', 'action': 'start', 'params': {'target_hours': 24}})
    check("F1: already running ok", not result7['ok'])
    check("F2: already running message", 'already running' in result7['message'])

    # G. stop, reset, unknown
    ctrl8 = FakeController()
    runner8 = make_runner(ctrl8, req_dir)
    result8 = runner8.handle_request({'id': '1', 'action': 'stop', 'params': {}})
    check("G1: stop ok", result8['ok'])
    check("G2: stop message", result8['message'] == 'stopped')

    ctrl9 = FakeController()
    ctrl9.stop_result = False
    runner9 = make_runner(ctrl9, req_dir)
    result9 = runner9.handle_request({'id': '1', 'action': 'stop', 'params': {}})
    check("G3: stop not running", result9['ok'] and result9['message'] == 'nothing was running')

    ctrl10 = FakeController()
    runner10 = make_runner(ctrl10, req_dir)
    result10 = runner10.handle_request({'id': '1', 'action': 'reset', 'params': {}})
    check("G4: reset ok", result10['ok'] and result10['message'] == 'reset')

    result11 = runner10.handle_request({'id': '1', 'action': 'explode', 'params': {}})
    check("G5: unknown action", not result11['ok'])

    # H. controller exception
    ctrl11 = FakeController()
    def boom_start(*args, **kwargs):
        raise RuntimeError("boom")
    ctrl11.start_survey = boom_start
    runner11 = make_runner(ctrl11, req_dir)
    try:
        result12 = runner11.handle_request({'id': '1', 'action': 'start', 'params': {'target_hours': 24}})
        check("H1: exception caught", not result12['ok'])
        check("H2: error message", 'RuntimeError: boom' in result12['message'])
    except Exception:
        check("H1: exception caught", False)

    # I. end to end with real files
    with tempfile.TemporaryDirectory() as e2e_dir:
        ctrl12 = FakeController()
        runner12 = make_runner(ctrl12, e2e_dir)
        rid = survey_requests.submit_request('start', {'target_hours': 24}, request_dir=e2e_dir)
        result13 = runner12.run_once()
        check("I1: run_once processes", result13 == True)
        start_calls = [c for c in ctrl12.calls if isinstance(c, tuple) and c[0] == 'start']
        check("I2: controller got start", len(start_calls) == 1 and start_calls[0] == ('start', 24))
        wait_result = survey_requests.wait_for_result(rid, 1, request_dir=e2e_dir)
        check("I3: wait_for_result ok", wait_result is not None and wait_result['ok'])
        result14 = runner12.run_once()
        check("I4: second run_once False", result14 == False)

    # J. run loop
    with tempfile.TemporaryDirectory() as loop_dir:
        ctrl13 = FakeController()
        runner13 = make_runner(ctrl13, loop_dir, poll_interval=0.05, status_interval=0.1)
        stop_event3 = threading.Event()
        thread3 = threading.Thread(target=runner13.run, args=(stop_event3,))
        thread3.start()
        time.sleep(0.1)
        rid2 = survey_requests.submit_request('stop', {}, request_dir=loop_dir)
        wait_result2 = survey_requests.wait_for_result(rid2, 3, request_dir=loop_dir)
        check("J1: run loop processes stop", wait_result2 is not None and wait_result2['ok'])
        timeout = time.time() + 2
        while 'status' not in ctrl13.calls and time.time() < timeout:
            time.sleep(0.05)
        check("J2: status reported", 'status' in ctrl13.calls)
        stop_event3.set()
        thread3.join(timeout=2)
        check("J3: thread ends", not thread3.is_alive())
        check("J4: no reset call", 'reset' not in ctrl13.calls)

    # K. failing write_result
    with tempfile.TemporaryDirectory() as wr_dir:
        original_write = survey_requests.write_result
        def failing_write(*args, **kwargs):
            raise OSError('disk full')
        survey_requests.write_result = failing_write
        try:
            ctrl14 = FakeController()
            runner14 = make_runner(ctrl14, wr_dir)
            rid3 = survey_requests.submit_request('reset', {}, request_dir=wr_dir)
            try:
                result15 = runner14.run_once()
                check("K1: run_once returns True", result15 == True)
                check("K2: reset called", 'reset' in ctrl14.calls)
            except Exception:
                check("K1: run_once returns True", False)
        finally:
            survey_requests.write_result = original_write

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(failed)
PYEOF

exit $FAIL
