#!/usr/bin/env bash
set -uo pipefail

REPO="${GM_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not found"
    exit 0
fi

python3 - "$REPO" <<'PYEOF'
import sys
import ast
import types
import tempfile
import threading
import time

REPO = sys.argv[1]
passed = 0
failed = 0

def report(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"PASS: {name}")
    else:
        failed += 1
        print(f"FAIL: {name}" + (f" - {detail}" if detail else ""))

src_path = f"{REPO}/web_app/server.py"
with open(src_path, "r") as f:
    src = f.read()

tree = ast.parse(src)
func_srcs = {}
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name in ("get_survey_controller", "_fresh_survey_state", "_survey_request"):
        func_srcs[node.name] = ast.get_source_segment(src, node)

ns = {
    "subprocess": types.SimpleNamespace(run=lambda *a, **k: types.SimpleNamespace(returncode=0, stderr="")),
    "SURVEY_SERVICE_UNIT": "geomaxima_survey.service",
    "_survey_controller": None,
}

class FakeState:
    def __init__(self):
        self.reloads = 0
    def reload(self):
        self.reloads += 1
        return True

class SurveyController:
    instances = 0
    recover_calls = 0
    def __init__(self):
        SurveyController.instances += 1
        self.state = FakeState()
    def recover_survey(self):
        SurveyController.recover_calls += 1

ns["SurveyController"] = SurveyController

sys.path.insert(0, REPO)
addons = types.ModuleType("addons")
addons.__path__ = []
sys.modules["addons"] = addons
features = types.ModuleType("addons.features")
features.__path__ = []
sys.modules["addons.features"] = features
auto_survey = types.ModuleType("addons.features.auto_survey")
auto_survey.__path__ = []
sys.modules["addons.features.auto_survey"] = auto_survey

sr_path = f"{REPO}/addons/features/auto_survey/survey_requests.py"
with open(sr_path, "r") as f:
    sr_src = f.read()
sr_tree = ast.parse(sr_src)
sr_code = compile(sr_tree, sr_path, "exec")
sr_module = types.ModuleType("addons.features.auto_survey.survey_requests")
exec(sr_code, sr_module.__dict__)
sys.modules["addons.features.auto_survey.survey_requests"] = sr_module
auto_survey.survey_requests = sr_module

for name, src in func_srcs.items():
    code = compile(src, f"<{name}>", "exec")
    exec(code, ns)

def test_a():
    d = tempfile.mkdtemp()
    called_with = []
    def fake_run(cmd, *a, **k):
        called_with.append(cmd)
        return types.SimpleNamespace(returncode=0, stderr="")
    ns["subprocess"].run = fake_run
    def responder():
        while True:
            req = sr_module.take_next_request(request_dir=d)
            if req is not None:
                sr_module.write_result(req["id"], True, "started", request_dir=d)
                return
    t = threading.Thread(target=responder)
    t.start()
    time.sleep(0.1)
    result = ns["_survey_request"]("start", {"target_hours": 24}, timeout=5, request_dir=d)
    t.join(timeout=5)
    ok = (result is not None and result.get("ok") == True and result.get("message") == "started"
          and len(called_with) > 0 and called_with[0] == ["systemctl", "start", "geomaxima_survey.service"])
    report("start_survey_with_responder", ok, f"result={result}, called={called_with}")

try:
    test_a()
except Exception as e:
    report("start_survey_with_responder", False, str(e))

def test_b():
    d = tempfile.mkdtemp()
    result = ns["_survey_request"]("stop", timeout=0.5, request_dir=d)
    req = sr_module.take_next_request(request_dir=d)
    ok = (result is None and req is None)
    report("stop_survey_no_responder", ok, f"result={result}, req={req}")

try:
    test_b()
except Exception as e:
    report("stop_survey_no_responder", False, str(e))

def test_c():
    d = tempfile.mkdtemp()
    def fake_run(cmd, *a, **k):
        return types.SimpleNamespace(returncode=1, stderr="unit not found")
    ns["subprocess"].run = fake_run
    try:
        ns["_survey_request"]("start", timeout=5, request_dir=d)
        ok = False
        detail = "no exception raised"
    except RuntimeError as e:
        msg = str(e)
        ok = "could not be started" in msg and "unit not found" in msg
        detail = f"msg={msg}"
    req = sr_module.take_next_request(request_dir=d)
    ok = ok and req is None
    report("start_survey_subprocess_failure", ok, detail)

try:
    test_c()
except Exception as e:
    report("start_survey_subprocess_failure", False, str(e))

def test_d():
    ns["_survey_controller"] = None
    SurveyController.instances = 0
    SurveyController.recover_calls = 0
    c1 = ns["get_survey_controller"]()
    c2 = ns["get_survey_controller"]()
    ok = (c1 is c2 and SurveyController.instances == 1 and SurveyController.recover_calls == 0)
    report("singleton_controller", ok, f"instances={SurveyController.instances}, recover={SurveyController.recover_calls}")

try:
    test_d()
except Exception as e:
    report("singleton_controller", False, str(e))

def test_e():
    ns["_survey_controller"] = None
    SurveyController.instances = 0
    c = ns["get_survey_controller"]()
    state = ns["_fresh_survey_state"]()
    ok = (state is c.state and state.reloads == 1)
    report("fresh_survey_state", ok, f"reloads={state.reloads}")

try:
    test_e()
except Exception as e:
    report("fresh_survey_state", False, str(e))

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(failed)
PYEOF

exit $?
