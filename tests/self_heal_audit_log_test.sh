#!/usr/bin/env bash
# Unit-style test for web_app/server.py's _self_heal_audit_log_and_journald()
# decision logic (2026-10-13 review fix, item b) - confirms the
# needs_fix check correctly detects wrong mode/ownership and correctly
# recognizes already-correct state (never re-runs install.sh
# needlessly, and never stays silent when a real fix is needed).
#
# Tests the mode/ownership CHECK logic directly (extracted, matching
# this file's own real conditions) rather than the full function (which
# needs Flask/rtkbaseconfig/a real install.sh subprocess call) - same
# "test the decision logic in isolation" approach used elsewhere in
# this suite for server.py pieces that are hard to import standalone.
set -uo pipefail
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

PYTHON=python3
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "SKIP: no python3 available in this environment"
  exit 0
fi

W="$(mktemp -d /tmp/gm_selfheal_test.XXXXXX)"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

check() {
  local mode="$1" owner_gid_matches="$2" exists="$3" expected="$4"
  local result
  result=$("$PYTHON" - "$mode" "$owner_gid_matches" "$exists" << 'PYEOF'
import sys, stat as stat_module
mode, owner_gid_matches, exists = sys.argv[1], sys.argv[2] == "True", sys.argv[3] == "True"

# Mirrors _self_heal_audit_log_and_journald()'s own decision logic.
needs_fix = True
if exists:
    mode_ok = stat_module.S_IMODE(int(mode, 8)) == 0o660
    owner_ok = owner_gid_matches
    needs_fix = not (mode_ok and owner_ok)
print("NEEDS_FIX" if needs_fix else "OK")
PYEOF
)
  if [[ "$result" == "$expected" ]]; then
    ok "mode=$mode owner_matches=$owner_gid_matches exists=$exists -> $result (expected $expected)"
  else
    bad "mode=$mode owner_matches=$owner_gid_matches exists=$exists -> $result (expected $expected)"
  fi
}

echo "== File does not exist yet -> always needs fix (creates it) =="
check "644" "False" "False" "NEEDS_FIX"

echo "== Confirmed-live bad state: root:root 0644 -> needs fix =="
check "644" "False" "True" "NEEDS_FIX"

echo "== Correct state: 0660 with matching group -> no fix needed =="
check "660" "True" "True" "OK"

echo "== Wrong mode (0644) but correct group -> still needs fix =="
check "644" "True" "True" "NEEDS_FIX"

echo "== Correct mode (0660) but wrong group -> still needs fix =="
check "660" "False" "True" "NEEDS_FIX"

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
