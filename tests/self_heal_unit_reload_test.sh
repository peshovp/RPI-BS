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
import types
import contextlib
import io

repo = sys.argv[1]
server_path = repo + "/web_app/server.py"
with open(server_path, "r") as f:
    source = f.read()

tree = ast.parse(source)
func_node = None
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "_self_heal_unit_reload":
        func_node = node
        break

if func_node is None:
    print("FAIL: _self_heal_unit_reload not found")
    print("RESULT: 0 passed, 1 failed")
    sys.exit(1)

func_source = ast.get_source_segment(source, func_node)

log_events = []
def log_event(category, event, details):
    log_events.append((category, event, details))

ns = {"log_event": log_event, "print": print}
exec(func_source, ns)
self_heal_unit_reload = ns["_self_heal_unit_reload"]

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
    global log_events
    log_events = []
    
    class FakeModule:
        pass
    
    fake_addons = FakeModule()
    fake_unit_reload = FakeModule()
    fake_unit_reload.reload_and_restart_changed = lambda: {
        'reloaded': False, 'units': [], 'returncode': None,
        'still_needing_reload': [], 'restarted': [], 'restart_failed': []
    }
    fake_addons.unit_reload_check = fake_unit_reload
    
    sys.modules['addons'] = fake_addons
    sys.modules['addons.unit_reload_check'] = fake_unit_reload
    
    try:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            self_heal_unit_reload()
        output = buf.getvalue()
        
        assert len(log_events) == 0, f"Expected no log events, got {len(log_events)}"
        assert output == "", f"Expected no output, got: {output}"
    finally:
        del sys.modules['addons']
        del sys.modules['addons.unit_reload_check']

def case_b():
    global log_events
    log_events = []
    
    class FakeModule:
        pass
    
    fake_addons = FakeModule()
    fake_unit_reload = FakeModule()
    fake_unit_reload.reload_and_restart_changed = lambda: {
        'reloaded': True, 'units': ['str2str_ntrip_A.service'], 'returncode': 0,
        'still_needing_reload': [], 'restarted': ['str2str_ntrip_A.service'], 'restart_failed': []
    }
    fake_addons.unit_reload_check = fake_unit_reload
    
    sys.modules['addons'] = fake_addons
    sys.modules['addons.unit_reload_check'] = fake_unit_reload
    
    try:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            self_heal_unit_reload()
        output = buf.getvalue()
        
        assert len(log_events) == 1, f"Expected 1 log event, got {len(log_events)}"
        cat, event, details = log_events[0]
        assert cat == 'startup', f"Expected category 'startup', got {cat}"
        assert event == 'self_heal_unit_reload', f"Expected event 'self_heal_unit_reload', got {event}"
        assert details['units'] == ['str2str_ntrip_A.service'], f"Wrong units: {details['units']}"
        assert details['restarted'] == ['str2str_ntrip_A.service'], f"Wrong restarted: {details['restarted']}"
        assert 'daemon-reload applied' in output, f"Expected 'daemon-reload applied' in output: {output}"
    finally:
        del sys.modules['addons']
        del sys.modules['addons.unit_reload_check']

def case_c():
    global log_events
    log_events = []
    
    class FakeModule:
        pass
    
    fake_addons = FakeModule()
    fake_unit_reload = FakeModule()
    fake_unit_reload.reload_and_restart_changed = lambda: {
        'reloaded': True, 'units': ['str2str_ntrip_A.service'], 'returncode': 0,
        'still_needing_reload': ['str2str_ntrip_A.service'], 'restarted': [], 'restart_failed': []
    }
    fake_addons.unit_reload_check = fake_unit_reload
    
    sys.modules['addons'] = fake_addons
    sys.modules['addons.unit_reload_check'] = fake_unit_reload
    
    try:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            self_heal_unit_reload()
        output = buf.getvalue()
        
        assert len(log_events) == 1, f"Expected 1 log event, got {len(log_events)}"
        cat, event, details = log_events[0]
        assert event == 'self_heal_unit_reload_failed', f"Expected event 'self_heal_unit_reload_failed', got {event}"
        assert 'did NOT clear' in output, f"Expected 'did NOT clear' in output: {output}"
    finally:
        del sys.modules['addons']
        del sys.modules['addons.unit_reload_check']

def case_d():
    global log_events
    log_events = []
    
    class FakeModule:
        pass
    
    fake_addons = FakeModule()
    fake_unit_reload = FakeModule()
    fake_unit_reload.reload_and_restart_changed = lambda: {
        'reloaded': True, 'units': ['str2str_ntrip_A.service'], 'returncode': 1,
        'still_needing_reload': [], 'restarted': [], 'restart_failed': []
    }
    fake_addons.unit_reload_check = fake_unit_reload
    
    sys.modules['addons'] = fake_addons
    sys.modules['addons.unit_reload_check'] = fake_unit_reload
    
    try:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            self_heal_unit_reload()
        output = buf.getvalue()
        
        assert len(log_events) == 1, f"Expected 1 log event, got {len(log_events)}"
        cat, event, details = log_events[0]
        assert event == 'self_heal_unit_reload_failed', f"Expected event 'self_heal_unit_reload_failed', got {event}"
    finally:
        del sys.modules['addons']
        del sys.modules['addons.unit_reload_check']

def case_e():
    global log_events
    log_events = []
    
    class FakeModule:
        pass
    
    fake_addons = FakeModule()
    fake_unit_reload = FakeModule()
    def raise_error():
        raise RuntimeError('boom')
    fake_unit_reload.reload_and_restart_changed = raise_error
    fake_addons.unit_reload_check = fake_unit_reload
    
    sys.modules['addons'] = fake_addons
    sys.modules['addons.unit_reload_check'] = fake_unit_reload
    
    try:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            self_heal_unit_reload()
        output = buf.getvalue()
        
        assert len(log_events) == 0, f"Expected no log events, got {len(log_events)}"
        assert 'continuing anyway' in output, f"Expected 'continuing anyway' in output: {output}"
    finally:
        del sys.modules['addons']
        del sys.modules['addons.unit_reload_check']

def case_f():
    global log_events
    log_events = []
    
    class FakeModule:
        pass
    
    fake_addons = FakeModule()
    fake_unit_reload = FakeModule()
    fake_unit_reload.reload_and_restart_changed = lambda: {'reloaded': True}
    fake_addons.unit_reload_check = fake_unit_reload
    
    sys.modules['addons'] = fake_addons
    sys.modules['addons.unit_reload_check'] = fake_unit_reload
    
    try:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            self_heal_unit_reload()
        output = buf.getvalue()
        
        assert len(log_events) == 1, f"Expected 1 log event, got {len(log_events)}"
        cat, event, details = log_events[0]
        assert event == 'self_heal_unit_reload_failed', f"Expected event 'self_heal_unit_reload_failed', got {event}"
    finally:
        del sys.modules['addons']
        del sys.modules['addons.unit_reload_check']

def case_g():
    main_idx = source.rfind('if __name__ == "__main__":')
    if main_idx == -1:
        raise AssertionError("No __main__ block found")
    
    main_block = source[main_idx:]
    
    reload_idx = main_block.find('_self_heal_unit_reload()')
    audit_idx = main_block.find('_self_heal_audit_log_and_journald()')
    password_idx = main_block.find('update_password(rtkbaseconfig)')
    
    if reload_idx == -1:
        raise AssertionError("_self_heal_unit_reload() not found in __main__ block")
    if audit_idx == -1:
        raise AssertionError("_self_heal_audit_log_and_journald() not found in __main__ block")
    if password_idx == -1:
        raise AssertionError("update_password(rtkbaseconfig) not found in __main__ block")
    
    assert audit_idx < reload_idx, "_self_heal_unit_reload() should come after _self_heal_audit_log_and_journald()"
    assert reload_idx < password_idx, "_self_heal_unit_reload() should come before update_password(rtkbaseconfig)"

run_case("A: no reload needed", case_a)
run_case("B: reload successful", case_b)
run_case("C: still_needing_reload not empty", case_c)
run_case("D: returncode != 0", case_d)
run_case("E: exception raised", case_e)
run_case("F: missing keys", case_f)
run_case("G: source order", case_g)

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(1 if failed > 0 else 0)
PYEOF
exit $?
