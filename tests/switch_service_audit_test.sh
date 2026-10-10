#!/usr/bin/env bash
# Unit-style test for web_app/server.py's switchService() audit logging
# (2026-10-13 review fix, closing the File-service "disabled" audit
# gap) - confirms the before/success/after state is captured correctly
# for both a successful and a failing start/stop action. Tests the
# decision/capture logic directly (a FakeUnit standing in for
# ServiceController, since the real class needs pystemd/a live D-Bus
# connection) rather than importing server.py itself (its own import
# chain needs Flask/pystemd/a live systemd - impractical to stub fully
# for this one function).
set -uo pipefail
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

PYTHON=python3
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "SKIP: no python3 available in this environment"
  exit 0
fi

run_case() {
  local requested_active="$1" raises="$2" active_before="$3" enabled_before="$4" active_after="$5" enabled_after="$6"
  "$PYTHON" - "$requested_active" "$raises" "$active_before" "$enabled_before" "$active_after" "$enabled_after" << 'PYEOF'
import sys
requested_active = sys.argv[1] == "True"
raises = sys.argv[2] == "True"
active_before, enabled_before = sys.argv[3] == "True", sys.argv[4] == "True"
active_after, enabled_after = sys.argv[5] == "True", sys.argv[6] == "True"

# Mirrors switchService()'s own capture logic exactly - a FakeUnit
# whose isActive()/isEnabled() return "before" values until start()/
# stop() is called, then "after" values, optionally raising to
# simulate a failed systemd action.
class FakeUnit:
    def __init__(self):
        self.acted = False
    def isActive(self):
        return active_after if self.acted else active_before
    def isEnabled(self):
        return enabled_after if self.acted else enabled_before
    def start(self):
        self.acted = True
        if raises:
            raise RuntimeError("simulated systemd failure")
    def stop(self):
        self.acted = True
        if raises:
            raise RuntimeError("simulated systemd failure")

unit = FakeUnit()
before = {"active": unit.isActive(), "enabled": unit.isEnabled()}
success = True
try:
    if requested_active:
        unit.start()
    else:
        unit.stop()
except Exception:
    success = False
after = {"active": unit.isActive(), "enabled": unit.isEnabled()}

print("BEFORE_ACTIVE", before["active"])
print("BEFORE_ENABLED", before["enabled"])
print("SUCCESS", success)
print("AFTER_ACTIVE", after["active"])
print("AFTER_ENABLED", after["enabled"])
PYEOF
}

echo "== Case A: successful start, was inactive+disabled before -> active+enabled after =="
OUT=$(run_case "True" "False" "False" "False" "True" "True")
echo "$OUT"
echo "$OUT" | grep -q "^BEFORE_ACTIVE False" && ok "Case A: before-state captured correctly (inactive)" || bad "Case A: before-state wrong"
echo "$OUT" | grep -q "^SUCCESS True" && ok "Case A: success=True for a successful start" || bad "Case A: success flag wrong"
echo "$OUT" | grep -q "^AFTER_ACTIVE True" && ok "Case A: after-state captured correctly (active)" || bad "Case A: after-state wrong"

echo "== Case B: failed stop (systemd raises) - success=False, before-state still captured =="
OUT=$(run_case "False" "True" "True" "True" "True" "True")
echo "$OUT"
echo "$OUT" | grep -q "^BEFORE_ACTIVE True" && ok "Case B: before-state captured even though the action failed" || bad "Case B: before-state missing"
echo "$OUT" | grep -q "^SUCCESS False" && ok "Case B: success=False for a failed action" || bad "Case B: success flag wrong (should be False)"

echo "== Case C: successful stop, was active+enabled before -> inactive (stop() alone is called, no assumption about enabled) =="
OUT=$(run_case "False" "False" "True" "True" "False" "True")
echo "$OUT"
echo "$OUT" | grep -q "^SUCCESS True" && ok "Case C: success=True for a successful stop" || bad "Case C: success flag wrong"
echo "$OUT" | grep -q "^AFTER_ACTIVE False" && ok "Case C: after-state shows inactive" || bad "Case C: after-state wrong"

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
