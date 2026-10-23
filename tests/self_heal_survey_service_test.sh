#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${GM_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not found"
    exit 0
fi

python3 - "$REPO" <<'PYEOF'
import ast
import sys
import json
import os
import pathlib
import tempfile
import types

repo = sys.argv[1]
server_path = repo + "/web_app/server.py"
with open(server_path, "r") as f:
    source = f.read()

tree = ast.parse(source)
func_node = None
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "_self_heal_survey_service":
        func_node = node
        break

if func_node is None:
    print("FAIL: _self_heal_survey_service not found")
    print("RESULT: 0 passed, 1 failed")
    sys.exit(1)

func_source = ast.get_source_segment(source, func_node)

log_events = []
def log_event(category, event, details):
    log_events.append((category, event, details))

calls = []
def make_fake_run(results):
    def fake_run(args, **kw):
        calls.append(args)
        cmd_word = args[1] if len(args) > 1 else ''
        if cmd_word in results:
            r = results[cmd_word]
            return type('Result', (), {'returncode': r.get('returncode', 0), 'stderr': r.get('stderr', '')})()
        return type('Result', (), {'returncode': 0, 'stderr': ''})()
    return fake_run

fake_subprocess = types.ModuleType('subprocess')
fake_subprocess.run = make_fake_run({})

ns = {
    "json": json,
    "os": os,
    "Path": pathlib.Path,
    "SURVEY_SERVICE_UNIT": "geomaxima_survey.service",
    "log_event": log_event,
    "subprocess": fake_subprocess,
    "print": print
}

exec(func_source, ns)
self_heal_survey_service = ns["_self_heal_survey_service"]

passed = 0
failed = 0

def run_case(name, test_func):
    global passed, failed
    try:
        test_func()
        passed += 1
        print(f"PASS: {name}")
    except Exception as e:
        failed += 1
        print(f"FAIL: {name}: {e}")

def case_a():
    global log_events, calls
    log_events = []
    calls = []
    fake_subprocess.run = make_fake_run({})
    
    with tempfile.TemporaryDirectory() as tmpdir:
        state_file = os.path.join(tmpdir, "state.json")
        self_heal_survey_service(state_file)
    
    assert len(calls) == 0, f"Expected no subprocess calls, got {len(calls)}"
    assert len(log_events) == 0, f"Expected no log events, got {len(log_events)}"

def case_b():
    global log_events, calls
    for state in ["idle", "completed", "failed"]:
        log_events = []
        calls = []
        fake_subprocess.run = make_fake_run({})
        
        with tempfile.TemporaryDirectory() as tmpdir:
            state_file = os.path.join(tmpdir, "state.json")
            with open(state_file, "w") as f:
                json.dump({"survey_state": state}, f)
            self_heal_survey_service(state_file)
        
        assert len(calls) == 0, f"State {state}: expected no calls, got {len(calls)}"
        assert len(log_events) == 0, f"State {state}: expected no log events"

def case_c():
    global log_events, calls
    log_events = []
    calls = []
    fake_subprocess.run = make_fake_run({"is-active": {"returncode": 0}})
    
    with tempfile.TemporaryDirectory() as tmpdir:
        state_file = os.path.join(tmpdir, "state.json")
        with open(state_file, "w") as f:
            json.dump({"survey_state": "running"}, f)
        self_heal_survey_service(state_file)
    
    assert len(calls) == 1, f"Expected 1 call, got {len(calls)}"
    assert calls[0][1] == "is-active", f"Expected is-active, got {calls[0][1]}"
    assert len(log_events) == 0, f"Expected no log events, got {len(log_events)}"

def case_d():
    global log_events, calls
    log_events = []
    calls = []
    fake_subprocess.run = make_fake_run({
        "is-active": {"returncode": 3},
        "start": {"returncode": 0}
    })
    
    with tempfile.TemporaryDirectory() as tmpdir:
        state_file = os.path.join(tmpdir, "state.json")
        with open(state_file, "w") as f:
            json.dump({"survey_state": "running"}, f)
        self_heal_survey_service(state_file)
    
    assert len(calls) == 2, f"Expected 2 calls, got {len(calls)}"
    assert calls[0][1] == "is-active", f"First call should be is-active"
    assert calls[1][1] == "start", f"Second call should be start"
    assert "geomaxima_survey.service" in calls[1], f"Unit name not in start call"
    assert len(log_events) == 1, f"Expected 1 log event"
    cat, event, details = log_events[0]
    assert event == "self_heal_survey_service", f"Wrong event"
    assert details["survey_state"] == "running", f"Wrong survey_state in details"

def case_d2():
    global log_events, calls
    log_events = []
    calls = []
    fake_subprocess.run = make_fake_run({})
    
    with tempfile.TemporaryDirectory() as tmpdir:
        state_file = os.path.join(tmpdir, "state.json")
        with open(state_file, "w") as f:
            json.dump({"survey_state": "paused"}, f)
        self_heal_survey_service(state_file)
    
    assert len(calls) == 0, f"Expected no subprocess calls, got {len(calls)}"
    assert len(log_events) == 0, f"Expected no log events, got {len(log_events)}"

def case_e():
    global log_events, calls
    log_events = []
    calls = []
    fake_subprocess.run = make_fake_run({
        "is-active": {"returncode": 3},
        "start": {"returncode": 1, "stderr": "unit not found"}
    })
    
    with tempfile.TemporaryDirectory() as tmpdir:
        state_file = os.path.join(tmpdir, "state.json")
        with open(state_file, "w") as f:
            json.dump({"survey_state": "running"}, f)
        self_heal_survey_service(state_file)
    
    assert len(log_events) == 1, f"Expected 1 log event, got {len(log_events)}"
    cat, event, details = log_events[0]
    assert event == "self_heal_survey_service_failed", f"Expected failed event, got {event}"
    assert "unit not found" in details.get("error", ""), f"Error message not in details"

def case_f():
    global log_events, calls
    log_events = []
    calls = []
    fake_subprocess.run = make_fake_run({})
    
    with tempfile.TemporaryDirectory() as tmpdir:
        state_file = os.path.join(tmpdir, "state.json")
        with open(state_file, "w") as f:
            f.write("not json")
        self_heal_survey_service(state_file)
    
    assert len(calls) == 0, f"Expected no calls, got {len(calls)}"

def case_g():
    global log_events, calls
    log_events = []
    calls = []
    fake_subprocess.run = make_fake_run({})
    
    with tempfile.TemporaryDirectory() as tmpdir:
        state_file = os.path.join(tmpdir, "state.json")
        with open(state_file, "w") as f:
            json.dump([1, 2], f)
        self_heal_survey_service(state_file)
    
    assert len(calls) == 0, f"Expected no calls, got {len(calls)}"

def case_h():
    global log_events, calls
    log_events = []
    calls = []
    
    def raising_run(args, **kw):
        calls.append(args)
        raise OSError("boom")
    
    fake_subprocess.run = raising_run
    
    with tempfile.TemporaryDirectory() as tmpdir:
        state_file = os.path.join(tmpdir, "state.json")
        with open(state_file, "w") as f:
            json.dump({"survey_state": "running"}, f)
        self_heal_survey_service(state_file)
    
    success_events = [e for e in log_events if e[1] == "self_heal_survey_service"]
    assert len(success_events) == 0, f"Expected no success log events, got {len(success_events)}"

def case_i():
    main_idx = source.rfind('if __name__ == "__main__":')
    if main_idx == -1:
        raise AssertionError("No __main__ block found")
    
    main_block = source[main_idx:]
    
    survey_idx = main_block.find('_self_heal_survey_service()')
    reload_idx = main_block.find('_self_heal_unit_reload()')
    password_idx = main_block.find('update_password(rtkbaseconfig')
    
    if survey_idx == -1:
        raise AssertionError("_self_heal_survey_service() not found in __main__ block")
    if reload_idx == -1:
        raise AssertionError("_self_heal_unit_reload() not found in __main__ block")
    if password_idx == -1:
        raise AssertionError("update_password(rtkbaseconfig not found in __main__ block")
    
    assert reload_idx < survey_idx, "_self_heal_survey_service() should come after _self_heal_unit_reload()"
    assert survey_idx < password_idx, "_self_heal_survey_service() should come before update_password(rtkbase_config"

run_case("A: state file missing", case_a)
run_case("B: idle/completed/failed states", case_b)
run_case("C: running and active", case_c)
run_case("D: running and inactive", case_d)
run_case("D2: paused survey is not resumed", case_d2)
run_case("E: start fails", case_e)
run_case("F: corrupt state file", case_f)
run_case("G: state file is list", case_g)
run_case("H: subprocess raises", case_h)
run_case("I: source order", case_i)

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(1 if failed > 0 else 0)
PYEOF
exit $?
