#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not found"
    exit 0
fi

python3 - "$REPO" <<'PYEOF'
import sys
import os
import tempfile
import importlib.util
import shutil

REPO = sys.argv[1]

# Build module path in two pieces
mod_name = 'unit_reload_check'
mod_file = mod_name + '.py'
mod_path = os.path.join(REPO, 'addons', mod_file)

passed = 0
failed = 0

def check(name, condition):
    global passed, failed
    if condition:
        passed += 1
    else:
        failed += 1
        print(f"FAIL: {name}")

def write_file(path, content):
    with open(path, 'w') as f:
        f.write(content)

def read_file(path):
    with open(path, 'r') as f:
        return f.read()

def remove_file(path):
    if os.path.exists(path):
        os.remove(path)

# Load module
try:
    spec = importlib.util.spec_from_file_location(mod_name, mod_path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
except Exception as e:
    print(f"FAIL: could not load module - {e}")
    print("RESULT: 0 passed, 1 failed")
    sys.exit(1)

# Create temp dir
tmpdir = tempfile.mkdtemp()
bindir = os.path.join(tmpdir, 'bin')
os.makedirs(bindir)

# Write stub systemctl
stub_path = os.path.join(bindir, 'systemctl')
stub_content = '''#!/bin/bash
W="${GM_TEST_W:-/tmp}"
cmd="$1"
shift

case "$cmd" in
    list-unit-files)
        echo "str2str_ntrip_A.service enabled"
        echo "rtkbase_web.service enabled"
        echo "str2str_file.service enabled"
        echo "rtkbase_archive.timer enabled"
        echo "geomaxima_watchdog.service enabled"
        ;;
    show)
        unit=""
        for arg in "$@"; do
            if [[ "$arg" == *.service || "$arg" == *.timer ]]; then
                unit="$arg"
            fi
        done
        if [ -f "$W/need" ] && grep -qx "$unit" "$W/need"; then
            if [ ! -f "$W/reloaded" ] || grep -qx "$unit" "$W/stuck" 2>/dev/null; then
                echo "yes"
            else
                echo "no"
            fi
        else
            echo "no"
        fi
        ;;
    daemon-reload)
        echo "daemon-reload" >> "$W/calls"
        touch "$W/reloaded"
        if [ -f "$W/reload_rc" ]; then
            exit "$(cat "$W/reload_rc")"
        fi
        exit 0
        ;;
    is-active)
        unit=""
        for arg in "$@"; do
            if [[ "$arg" == *.service || "$arg" == *.timer ]]; then
                unit="$arg"
            fi
        done
        if [ -f "$W/active" ] && grep -qx "$unit" "$W/active"; then
            exit 0
        fi
        exit 3
        ;;
    restart)
        unit="$1"
        echo "restart $unit" >> "$W/calls"
        if [ -f "$W/restart_fail" ] && grep -qx "$unit" "$W/restart_fail"; then
            exit 1
        fi
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
'''
write_file(stub_path, stub_content)
os.chmod(stub_path, 0o755)

# Set up environment
os.environ['PATH'] = bindir + ':' + os.environ['PATH']
os.environ['GM_TEST_W'] = tmpdir

def reset_state():
    for f in ['need', 'active', 'stuck', 'reloaded', 'calls', 'reload_rc', 'restart_fail']:
        remove_file(os.path.join(tmpdir, f))

def run_case(name, setup, verify):
    global passed, failed
    reset_state()
    try:
        setup()
        result = mod.reload_and_restart_changed()
        verify(result)
    except Exception as e:
        failed += 1
        print(f"FAIL: {name} - {e}")

# Case A: need empty
def setup_a():
    pass

def verify_a(result):
    check("A: reloaded is False", result['reloaded'] == False)
    check("A: restarted is empty", result['restarted'] == [])
    calls_path = os.path.join(tmpdir, 'calls')
    check("A: no calls", not os.path.exists(calls_path))

run_case("A", setup_a, verify_a)

# Case B: need 3 units, 2 active
def setup_b():
    write_file(os.path.join(tmpdir, 'need'), "str2str_ntrip_A.service\nrtkbase_archive.timer\ngeomaxima_watchdog.service\n")
    write_file(os.path.join(tmpdir, 'active'), "str2str_ntrip_A.service\nrtkbase_archive.timer\n")

def verify_b(result):
    calls_path = os.path.join(tmpdir, 'calls')
    calls = read_file(calls_path) if os.path.exists(calls_path) else ""
    check("B: daemon-reload happened", "daemon-reload" in calls)
    check("B: restarted correct", result['restarted'] == ['rtkbase_archive.timer', 'str2str_ntrip_A.service'])
    check("B: no restart geomaxima", "restart geomaxima_watchdog.service" not in calls)
    check("B: restart_failed empty", result['restart_failed'] == [])

run_case("B", setup_b, verify_b)

# Case C: need 2 units, both active, but no restart needed
def setup_c():
    write_file(os.path.join(tmpdir, 'need'), "rtkbase_web.service\nstr2str_file.service\n")
    write_file(os.path.join(tmpdir, 'active'), "rtkbase_web.service\nstr2str_file.service\n")

def verify_c(result):
    calls_path = os.path.join(tmpdir, 'calls')
    calls = read_file(calls_path) if os.path.exists(calls_path) else ""
    check("C: daemon-reload happened", "daemon-reload" in calls)
    check("C: no restart lines", "restart" not in calls)
    check("C: restarted empty", result['restarted'] == [])

run_case("C", setup_c, verify_c)

# Case D: stuck unit
def setup_d():
    write_file(os.path.join(tmpdir, 'need'), "str2str_ntrip_A.service\n")
    write_file(os.path.join(tmpdir, 'active'), "str2str_ntrip_A.service\n")
    write_file(os.path.join(tmpdir, 'stuck'), "str2str_ntrip_A.service\n")

def verify_d(result):
    calls_path = os.path.join(tmpdir, 'calls')
    calls = read_file(calls_path) if os.path.exists(calls_path) else ""
    check("D: no restart lines", "restart" not in calls)
    check("D: restarted empty", result['restarted'] == [])
    check("D: still_needing_reload correct", result['still_needing_reload'] == ['str2str_ntrip_A.service'])

run_case("D", setup_d, verify_d)

# Case E: reload fails
def setup_e():
    write_file(os.path.join(tmpdir, 'need'), "str2str_ntrip_A.service\n")
    write_file(os.path.join(tmpdir, 'active'), "str2str_ntrip_A.service\n")
    write_file(os.path.join(tmpdir, 'reload_rc'), "1")

def verify_e(result):
    calls_path = os.path.join(tmpdir, 'calls')
    calls = read_file(calls_path) if os.path.exists(calls_path) else ""
    check("E: no restart lines", "restart" not in calls)
    check("E: restarted empty", result['restarted'] == [])

run_case("E", setup_e, verify_e)

# Case F: restart fails for one unit
def setup_f():
    write_file(os.path.join(tmpdir, 'need'), "str2str_ntrip_A.service\nrtkbase_archive.timer\n")
    write_file(os.path.join(tmpdir, 'active'), "str2str_ntrip_A.service\nrtkbase_archive.timer\n")
    write_file(os.path.join(tmpdir, 'restart_fail'), "rtkbase_archive.timer\n")

def verify_f(result):
    check("F: restarted correct", result['restarted'] == ['str2str_ntrip_A.service'])
    check("F: restart_failed correct", result['restart_failed'] == ['rtkbase_archive.timer'])

run_case("F", setup_f, verify_f)

# Cleanup
shutil.rmtree(tmpdir)

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(failed)
PYEOF
