#!/usr/bin/env bash
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

mkdir -p "$TMPDIR_TEST/bin"
export PATH="$TMPDIR_TEST/bin:$PATH"

cat > "$TMPDIR_TEST/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "list-unit-files" ] && [ "$2" = "--no-legend" ]; then
    for f in "$GM_TEST_UNITS_DIR"/*.ndr; do
        [ -f "$f" ] || continue
        base="$(basename "$f" .ndr)"
        echo "$base enabled"
    done
elif [ "$1" = "show" ] && [ "$2" = "-p" ] && [ "$3" = "NeedDaemonReload" ] && [ "$4" = "--value" ]; then
    unit="$5"
    f="$GM_TEST_UNITS_DIR/${unit}.ndr"
    if [ -f "$f" ]; then
        cat "$f"
    else
        echo "no"
    fi
elif [ "$1" = "daemon-reload" ]; then
    echo "daemon-reload" >> "$GM_TEST_UNITS_DIR/calls.log"
    for f in "$GM_TEST_UNITS_DIR"/*.ndr; do
        [ -f "$f" ] || continue
        base="$(basename "$f" .ndr)"
        stuck="no"
        if [ -n "${GM_TEST_STUCK_UNITS:-}" ]; then
            for s in $GM_TEST_STUCK_UNITS; do
                if [ "$s" = "$base" ]; then stuck="yes"; break; fi
            done
        fi
        if [ "$stuck" = "yes" ]; then
            echo "yes" > "$f"
        else
            echo "no" > "$f"
        fi
    done
    exit "${GM_TEST_RELOAD_RC:-0}"
else
    echo "$*" >> "$GM_TEST_UNITS_DIR/calls.log"
    exit 0
fi
EOF
chmod +x "$TMPDIR_TEST/bin/systemctl"

reset_state() {
    rm -rf "$TMPDIR_TEST/state"
    mkdir -p "$TMPDIR_TEST/state"
    export GM_TEST_UNITS_DIR="$TMPDIR_TEST/state"
    export GM_TEST_STUCK_UNITS=""
    export GM_TEST_RELOAD_RC=0
}

set_unit() {
    echo "$2" > "$GM_TEST_UNITS_DIR/${1}.ndr"
}

# Case A: units_needing_reload filters correctly
reset_state
set_unit "str2str_tcp.service" "yes"
set_unit "rtkbase_archive.service" "yes"
set_unit "str2str_file.service" "no"
set_unit "rtkbase_archive.timer" "no"
set_unit "ssh.service" "yes"
set_unit "str2str_x@.service" "yes"

source "$REPO/tools/unit_reload.sh"
out=$(geomaxima_units_needing_reload)
expected="rtkbase_archive.service
str2str_tcp.service"
if [ "$out" = "$expected" ]; then
    ok "A: units_needing_reload filters correctly"
else
    bad "A: units_needing_reload output: '$out'"
fi

# Case B: daemon-reload succeeds, clears all
reset_state
set_unit "str2str_tcp.service" "yes"
set_unit "rtkbase_archive.service" "yes"
set_unit "str2str_file.service" "no"
set_unit "rtkbase_archive.timer" "no"
set_unit "ssh.service" "yes"
set_unit "str2str_x@.service" "yes"

if geomaxima_daemon_reload_and_verify; then
    ok "B: daemon-reload returns 0"
else
    bad "B: daemon-reload returned non-zero"
fi
if [ "$(grep -c '^daemon-reload$' "$GM_TEST_UNITS_DIR/calls.log")" -eq 1 ]; then
    ok "B: calls.log contains daemon-reload exactly once"
else
    bad "B: calls.log daemon-reload count wrong"
fi
after=$(geomaxima_units_needing_reload)
if [ -z "$after" ]; then
    ok "B: no units need reload after"
else
    bad "B: still needing reload: '$after'"
fi

# Case C: stuck unit
reset_state
set_unit "str2str_tcp.service" "yes"
set_unit "rtkbase_archive.service" "yes"
export GM_TEST_STUCK_UNITS="str2str_tcp.service"

err=$(geomaxima_daemon_reload_and_verify 2>&1)
rc=$?
if [ $rc -eq 1 ]; then
    ok "C: returns 1 for stuck unit"
else
    bad "C: returned $rc, expected 1"
fi
if echo "$err" | grep -q "str2str_tcp.service"; then
    ok "C: stderr mentions stuck unit"
else
    bad "C: stderr missing stuck unit: '$err'"
fi

# Case D: daemon-reload fails
reset_state
set_unit "str2str_tcp.service" "yes"
export GM_TEST_RELOAD_RC=1

err=$(geomaxima_daemon_reload_and_verify 2>&1)
rc=$?
if [ $rc -eq 2 ]; then
    ok "D: returns 2 when daemon-reload fails"
else
    bad "D: returned $rc, expected 2"
fi
if echo "$err" | grep -q "daemon-reload failed (exit 1)"; then
    ok "D: stderr contains actual exit code"
else
    bad "D: stderr missing exit code: '$err'"
fi

# Python cases
if command -v python3 >/dev/null 2>&1; then
    # Case E: Python reload_if_needed
    reset_state
    set_unit "str2str_tcp.service" "yes"
    set_unit "rtkbase_archive.service" "yes"
    set_unit "str2str_file.service" "no"
    set_unit "rtkbase_archive.timer" "no"
    set_unit "ssh.service" "yes"
    set_unit "str2str_x@.service" "yes"

    py_out=$(python3 - "$REPO/addons/unit_reload_check.py" <<'PYEOF'
import sys, importlib.util, json
spec = importlib.util.spec_from_file_location("unit_reload_check", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
result = mod.reload_if_needed()
print(json.dumps(result))
PYEOF
    )
    if echo "$py_out" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
assert d['reloaded'] == True
assert d['units'] == ['rtkbase_archive.service', 'str2str_tcp.service']
assert d['returncode'] == 0
assert d['still_needing_reload'] == []
"; then
        ok "E: Python reload_if_needed works"
    else
        bad "E: Python reload_if_needed failed: $py_out"
    fi

    # Case F: Python idempotency
    reset_state
    set_unit "str2str_tcp.service" "no"
    set_unit "rtkbase_archive.service" "no"

    py_out=$(python3 - "$REPO/addons/unit_reload_check.py" <<'PYEOF'
import sys, importlib.util, json
spec = importlib.util.spec_from_file_location("unit_reload_check", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
result = mod.reload_if_needed()
print(json.dumps(result))
PYEOF
    )
    if echo "$py_out" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
assert d['reloaded'] == False
" && ! grep -q "daemon-reload" "$GM_TEST_UNITS_DIR/calls.log"; then
        ok "F: Python idempotent when no reload needed"
    else
        bad "F: Python idempotency failed: $py_out"
    fi
else
    echo "SKIP: python3 not available"
fi

echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
