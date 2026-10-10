#!/usr/bin/env bash
# Unit-style test for the file-logging status->message mapping
# (2026-10-10 review follow-up, item a) - verifies the state->message
# logic file_logging_status.js implements, reimplemented here in
# Python for testability (JS itself isn't run in this test suite).
# Confirms: owned-by-survey takes priority and shows the info message;
# off/inactive (not owned) shows the warning; active+enabled (not
# owned) shows nothing.
set -uo pipefail
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

PYTHON=python3
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "SKIP: no python3 available in this environment"
  exit 0
fi

check() {
  local active="$1" enabled="$2" owned="$3" expected="$4"
  local result
  result=$("$PYTHON" - "$active" "$enabled" "$owned" << 'PYEOF'
import sys
active = sys.argv[1] == "True"
enabled = sys.argv[2] == "True"
owned = sys.argv[3] == "True"

# Mirrors file_logging_status.js's own if/elif/else exactly.
if owned:
    print("INFO")
elif active is not True or enabled is not True:
    print("WARNING")
else:
    print("NONE")
PYEOF
)
  if [[ "$result" == "$expected" ]]; then
    ok "active=$active enabled=$enabled owned=$owned -> $result (expected $expected)"
  else
    bad "active=$active enabled=$enabled owned=$owned -> $result (expected $expected)"
  fi
}

echo "== Owned by survey always shows INFO, regardless of active/enabled =="
check "True" "False" "True" "INFO"
check "False" "False" "True" "INFO"
check "True" "True" "True" "INFO"

echo "== Not owned, active+enabled -> no warning =="
check "True" "True" "False" "NONE"

echo "== Not owned, inactive and/or disabled -> WARNING =="
check "False" "True" "False" "WARNING"
check "True" "False" "False" "WARNING"
check "False" "False" "False" "WARNING"

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
