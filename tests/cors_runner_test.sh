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

class FakeController:
    def __init__(self):
        self.is_runner = False
        self.calls = []
    def recover_survey(self):
        self.calls.append('recover')
        return False
    def get_status(self):
        self.calls.append('status')
        return {}
    def start_survey(self, target_hours=24, apply_mode='apply'):
        self.calls.append(('start', target_hours))
        return True
    def stop_survey(self):
        self.calls.append('stop')
        return True
    def reset_survey(self):
        self.calls.append('reset')
        return None

class FakeCors:
    def __init__(self):
        self.calls = []
        self.start_result = (True, "job123abc456")
        self.cancel_result = True
        self.apply_result = {"ok": True, "reason": None, "apply_result": {"applied": [42.6, 26.4, 200.0]}}
    def start(self, account_id, params=None):
        self.calls.append(("start", account_id))
        return self.start_result
    def cancel(self):
        self.calls.append("cancel")
        return self.cancel_result
    def apply(self, job_id, confirmed, force=False):
        self.calls.append(("apply", job_id, confirmed, force))
        return self.apply_result

def make_runner(cors=None, factory=None, request_dir=None):
    if factory is None:
        if cors is not None:
            factory = lambda controller: cors
        else:
            factory = None
    runner = mod.SurveyRunner(lambda: FakeController(), request_dir=request_dir, cors_manager_factory=factory)
    runner.startup()
    return runner

with tempfile.TemporaryDirectory() as req_dir:
    # A. cors_compute
    cors = FakeCors()
    runner = make_runner(cors=cors, request_dir=req_dir)
    result = runner.handle_request({"id": "1", "action": "cors_compute", "params": {"account_id": "acc1"}})
    check("A1: cors_compute ok", result["ok"])
    check("A2: cors_compute message", result["message"] == "started")
    check("A3: cors_compute job_id", result["data"] == {"job_id": "job123abc456"})
    check("A4: cors_compute recorded", ("start", "acc1") in cors.calls)

    cors2 = FakeCors()
    cors2.start_result = (False, "account is disabled")
    runner2 = make_runner(cors=cors2, request_dir=req_dir)
    result2 = runner2.handle_request({"id": "2", "action": "cors_compute", "params": {"account_id": "acc2"}})
    check("A5: cors_compute fail", not result2["ok"])
    check("A6: cors_compute fail message", result2["message"] == "account is disabled")
    check("A7: cors_compute fail data", result2["data"] is None)

    runner3 = make_runner(cors=FakeCors(), request_dir=req_dir)
    result3 = runner3.handle_request({"id": "3", "action": "cors_compute", "params": {"account_id": 5}})
    check("A8: cors_compute bad account_id type", not result3["ok"])
    check("A9: cors_compute bad account_id message", result3["message"] == "account_id must be a string")

    result4 = runner3.handle_request({"id": "4", "action": "cors_compute", "params": {}})
    check("A10: cors_compute missing account_id", not result4["ok"])
    check("A11: cors_compute missing account_id message", result4["message"] == "account_id must be a string")

    # B. no manager
    runner4 = make_runner(request_dir=req_dir)
    result5 = runner4.handle_request({"id": "5", "action": "cors_compute", "params": {"account_id": "acc"}})
    check("B1: no manager cors_compute", not result5["ok"] and result5["message"] == "CORS feature unavailable")
    result6 = runner4.handle_request({"id": "6", "action": "cors_cancel", "params": {}})
    check("B2: no manager cors_cancel", not result6["ok"] and result6["message"] == "CORS feature unavailable")
    result7 = runner4.handle_request({"id": "7", "action": "cors_apply", "params": {"job_id": "j"}})
    check("B3: no manager cors_apply", not result7["ok"] and result7["message"] == "CORS feature unavailable")

    # C. cors_cancel
    cors3 = FakeCors()
    runner5 = make_runner(cors=cors3, request_dir=req_dir)
    result8 = runner5.handle_request({"id": "8", "action": "cors_cancel", "params": {}})
    check("C1: cors_cancel ok", result8["ok"])
    check("C2: cors_cancel message", result8["message"] == "cancel requested")

    cors4 = FakeCors()
    cors4.cancel_result = False
    runner6 = make_runner(cors=cors4, request_dir=req_dir)
    result9 = runner6.handle_request({"id": "9", "action": "cors_cancel", "params": {}})
    check("C3: cors_cancel nothing running", result9["ok"] and result9["message"] == "nothing was running")

    # D. cors_apply
    cors5 = FakeCors()
    runner7 = make_runner(cors=cors5, request_dir=req_dir)
    result10 = runner7.handle_request({"id": "10", "action": "cors_apply", "params": {"job_id": "job123abc456", "confirmed": True}})
    check("D1: cors_apply ok", result10["ok"])
    check("D2: cors_apply message", result10["message"] == "applied")
    check("D3: cors_apply data", result10["data"] == {"applied": [42.6, 26.4, 200.0]})
    check("D4: cors_apply recorded", ("apply", "job123abc456", True, False) in cors5.calls)

    for val in ["true", 1, "yes", None]:
        cors6 = FakeCors()
        runner8 = make_runner(cors=cors6, request_dir=req_dir)
        runner8.handle_request({"id": "11", "action": "cors_apply", "params": {"job_id": "j", "confirmed": val}})
        apply_calls = [c for c in cors6.calls if isinstance(c, tuple) and c[0] == "apply"]
        check(f"D5: confirmed {val!r} -> False", len(apply_calls) == 1 and apply_calls[0][2] is False)

    cors7 = FakeCors()
    runner9 = make_runner(cors=cors7, request_dir=req_dir)
    runner9.handle_request({"id": "12", "action": "cors_apply", "params": {"job_id": "j"}})
    apply_calls2 = [c for c in cors7.calls if isinstance(c, tuple) and c[0] == "apply"]
    check("D6: missing confirmed -> False", len(apply_calls2) == 1 and apply_calls2[0][2] is False)

    cors8 = FakeCors()
    runner10 = make_runner(cors=cors8, request_dir=req_dir)
    runner10.handle_request({"id": "13", "action": "cors_apply", "params": {"job_id": "j", "force": True}})
    apply_calls3 = [c for c in cors8.calls if isinstance(c, tuple) and c[0] == "apply"]
    check("D7: force True", len(apply_calls3) == 1 and apply_calls3[0][3] is True)

    for val in ["true", 1, "yes", None]:
        cors9 = FakeCors()
        runner11 = make_runner(cors=cors9, request_dir=req_dir)
        runner11.handle_request({"id": "14", "action": "cors_apply", "params": {"job_id": "j", "force": val}})
        apply_calls4 = [c for c in cors9.calls if isinstance(c, tuple) and c[0] == "apply"]
        check(f"D8: force {val!r} -> False", len(apply_calls4) == 1 and apply_calls4[0][3] is False)

    cors10 = FakeCors()
    runner12 = make_runner(cors=cors10, request_dir=req_dir)
    result11 = runner12.handle_request({"id": "15", "action": "cors_apply", "params": {"job_id": 5}})
    check("D9: bad job_id type", not result11["ok"] and result11["message"] == "job_id must be a string")
    check("D10: bad job_id not called", len(cors10.calls) == 0)

    cors11 = FakeCors()
    cors11.apply_result = {"ok": False, "reason": "change too large", "apply_result": None}
    runner13 = make_runner(cors=cors11, request_dir=req_dir)
    result12 = runner13.handle_request({"id": "16", "action": "cors_apply", "params": {"job_id": "j", "confirmed": True}})
    check("D11: apply fail reason", not result12["ok"] and result12["message"] == "change too large")

    cors12 = FakeCors()
    cors12.apply_result = {"ok": False, "reason": None, "apply_result": None}
    runner14 = make_runner(cors=cors12, request_dir=req_dir)
    result13 = runner14.handle_request({"id": "17", "action": "cors_apply", "params": {"job_id": "j", "confirmed": True}})
    check("D12: apply fail no reason", not result13["ok"] and result13["message"] == "apply failed")

    # E. protocol
    check("E1: cors_compute allowed", "cors_compute" in survey_requests.ALLOWED_ACTIONS)
    check("E2: cors_cancel allowed", "cors_cancel" in survey_requests.ALLOWED_ACTIONS)
    check("E3: cors_apply allowed", "cors_apply" in survey_requests.ALLOWED_ACTIONS)
    check("E4: start still allowed", "start" in survey_requests.ALLOWED_ACTIONS)
    check("E5: stop still allowed", "stop" in survey_requests.ALLOWED_ACTIONS)
    check("E6: reset still allowed", "reset" in survey_requests.ALLOWED_ACTIONS)

    try:
        survey_requests.submit_request("cors_hack", {}, request_dir=req_dir)
        check("E7: invalid action raises", False)
    except ValueError:
        check("E7: invalid action raises", True)

    with tempfile.TemporaryDirectory() as e2e_dir:
        cors13 = FakeCors()
        runner15 = make_runner(cors=cors13, request_dir=e2e_dir)
        rid = survey_requests.submit_request("cors_compute", {"account_id": "acc9"}, request_dir=e2e_dir)
        handled = runner15.run_once()
        check("E8: run_once processes", handled)
        result14 = survey_requests.wait_for_result(rid, 5, request_dir=e2e_dir)
        check("E9: wait_for_result ok", result14 is not None and result14["ok"])
        check("E10: wait_for_result data", result14["data"] == {"job_id": "job123abc456"})

    # F. startup with factory
    factory_called_with = None
    def test_factory(controller):
        global factory_called_with
        factory_called_with = controller
        return FakeCors()
    runner16 = make_runner(factory=test_factory, request_dir=req_dir)
    check("F1: factory receives controller", factory_called_with is not None and isinstance(factory_called_with, FakeController))
    check("F2: runner.cors set", runner16.cors is not None)
    check("F3: controller reconciled", 'recover' in runner16.controller.calls)

    def failing_factory(controller):
        raise RuntimeError("boom")
    runner17 = make_runner(factory=failing_factory, request_dir=req_dir)
    check("F4: failing factory handled", runner17.cors is None)
    result15 = runner17.handle_request({"id": "18", "action": "cors_compute", "params": {"account_id": "acc"}})
    check("F5: failing factory unavailable", not result15["ok"] and result15["message"] == "CORS feature unavailable")
    check("F6: controller still reconciled", 'recover' in runner17.controller.calls)

    # G. existing actions still work
    runner18 = make_runner(cors=FakeCors(), request_dir=req_dir)
    result16 = runner18.handle_request({"id": "19", "action": "start", "params": {"target_hours": 24}})
    check("G1: start works", result16["ok"] and result16["message"] == "started")
    result17 = runner18.handle_request({"id": "20", "action": "stop", "params": {}})
    check("G2: stop works", result17["ok"] and result17["message"] == "stopped")
    result18 = runner18.handle_request({"id": "21", "action": "reset", "params": {}})
    check("G3: reset works", result18["ok"] and result18["message"] == "reset")
    result19 = runner18.handle_request({"id": "22", "action": "nope", "params": {}})
    check("G4: unknown action", not result19["ok"] and result19["message"] == "unknown action: nope")

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(failed)
PYEOF

exit $FAIL
