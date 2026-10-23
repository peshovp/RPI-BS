#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GM_REPO_ROOT="${GM_REPO_ROOT:-$(dirname "$SCRIPT_DIR")}"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not found"
    exit 0
fi

python3 <<'PYEOF'
import sys
import os
import types
import importlib.util

REPO = os.environ["GM_REPO_ROOT"]

# Load the service_monitor module
module_path = os.path.join(REPO, "addons", "features", "watchdog", "monitors", "service_monitor.py")
spec = importlib.util.spec_from_file_location("service_monitor", module_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

passed = 0
failed = 0

def run_case(name, test_fn):
    global passed, failed
    try:
        test_fn()
        passed += 1
        print(f"PASS: {name}")
    except Exception as e:
        failed += 1
        print(f"FAIL: {name}: {e}")

def make_monitor(config):
    return mod.ServiceMonitor(config)

def install_fake_units_needing_reload(units):
    """Install fake addons.unit_reload_check module with given units list."""
    addons = types.ModuleType("addons")
    unit_reload_check = types.ModuleType("addons.unit_reload_check")
    unit_reload_check.units_needing_reload = lambda: units
    addons.unit_reload_check = unit_reload_check
    sys.modules["addons"] = addons
    sys.modules["addons.unit_reload_check"] = unit_reload_check
    return addons, unit_reload_check

def remove_fake_modules():
    sys.modules.pop("addons", None)
    sys.modules.pop("addons.unit_reload_check", None)

def has_incident(result, inc_type):
    return any(inc["type"] == inc_type for inc in result.get("incidents", []))

def get_incidents(result, inc_type):
    return [inc for inc in result.get("incidents", []) if inc["type"] == inc_type]

# Case A: no units needing reload
def case_a():
    m = make_monitor({"services": []})
    install_fake_units_needing_reload([])
    try:
        result = m.check()
        assert not has_incident(result, "unit_needs_reload"), "unexpected unit_needs_reload incident"
        assert result["status"] == "ok", f"expected status 'ok', got '{result['status']}'"
    finally:
        remove_fake_modules()

# Case B: units needing reload
def case_b():
    m = make_monitor({"services": []})
    units = ["rtkbase_archive.service", "str2str_ntrip_A.service"]
    install_fake_units_needing_reload(units)
    try:
        result = m.check()
        incidents = get_incidents(result, "unit_needs_reload")
        assert len(incidents) == 2, f"expected 2 unit_needs_reload incidents, got {len(incidents)}"
        for inc in incidents:
            assert inc["severity"] == "warning", f"expected severity 'warning', got '{inc['severity']}'"
            assert inc["service"] in units, f"unexpected service '{inc['service']}'"
            assert "NeedDaemonReload=yes" in inc["message"], f"message missing 'NeedDaemonReload=yes': {inc['message']}"
        assert result["status"] == "warning", f"expected status 'warning', got '{result['status']}'"
    finally:
        remove_fake_modules()

# Case C: units_needing_reload raises
def case_c():
    m = make_monitor({"services": []})
    def raising():
        raise RuntimeError("boom")
    install_fake_units_needing_reload(None)
    sys.modules["addons.unit_reload_check"].units_needing_reload = raising
    try:
        result = m.check()
        assert not has_incident(result, "unit_needs_reload"), "unexpected unit_needs_reload incident"
        assert result["status"] == "ok", f"expected status 'ok', got '{result['status']}'"
    finally:
        remove_fake_modules()

# Case D: module cannot be imported
def case_d():
    m = make_monitor({"services": []})
    addons = types.ModuleType("addons")
    sys.modules["addons"] = addons
    try:
        result = m.check()
        assert not has_incident(result, "unit_needs_reload"), "unexpected unit_needs_reload incident"
        assert result["status"] == "ok", f"expected status 'ok', got '{result['status']}'"
    finally:
        remove_fake_modules()

# Case E: status never lowered
def case_e():
    m = make_monitor({"services": ["x.service"], "auto_restart": False})
    # Monkeypatch _check_service to return inactive
    def fake_check_service(name):
        return {"active": False, "enabled": True}
    m._check_service = fake_check_service
    install_fake_units_needing_reload(["y.service"])
    try:
        result = m.check()
        assert result["status"] == "warning", f"expected status 'warning', got '{result['status']}'"
        assert has_incident(result, "service_down"), "missing service_down incident"
        assert has_incident(result, "unit_needs_reload"), "missing unit_needs_reload incident"
    finally:
        remove_fake_modules()

run_case("A: no units needing reload", case_a)
run_case("B: units needing reload", case_b)
run_case("C: units_needing_reload raises", case_c)
run_case("D: module cannot be imported", case_d)
run_case("E: status never lowered", case_e)

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(failed)
PYEOF

exit $?
