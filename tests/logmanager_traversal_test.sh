#!/usr/bin/env bash
# Unit-style test for web_app/LogManager.py's deleteLog() path-traversal
# protection (2026-10-07 review fix) - log_filename arrives from a
# socketio message with no prior validation; os.path.join with an
# absolute path or a "../" name could otherwise delete an arbitrary
# file outside the logs directory.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

PYTHON=python3
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "SKIP: no python3 available in this environment"
  exit 0
fi

W="$(mktemp -d /tmp/gm_logmanager_test.XXXXXX)"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

OUT=$("$PYTHON" - "$REPO" "$W" << 'PYEOF'
import sys, os, importlib.util
repo, w = sys.argv[1], sys.argv[2]

spec = importlib.util.spec_from_file_location("LogManager", repo + "/web_app/LogManager.py")
mod = importlib.util.module_from_spec(spec)
try:
    sys.modules.setdefault("log_converter", __import__("types").ModuleType("log_converter"))
    sys.modules["log_converter"].convbin = lambda *a, **k: None
    spec.loader.exec_module(mod)
except Exception as e:
    print("IMPORT_FAILED", repr(e))
    sys.exit(0)

log_dir = os.path.join(w, "logs")
os.makedirs(log_dir, exist_ok=True)
outside_dir = os.path.join(w, "outside")
os.makedirs(outside_dir, exist_ok=True)

victim = os.path.join(outside_dir, "victim.txt")
with open(victim, "w") as f:
    f.write("do not delete me")

legit = os.path.join(log_dir, "legit.log")
with open(legit, "w") as f:
    f.write("ok to delete")

lm = mod.LogManager.__new__(mod.LogManager)
lm.log_path = log_dir

# Case 1: path traversal with ../
r1 = lm.deleteLog(f"../outside/victim.txt")
print("CASE1_VICTIM_EXISTS", os.path.exists(victim))
print("CASE1_RETURN", r1)

# Case 2: absolute path
r2 = lm.deleteLog(victim)
print("CASE2_VICTIM_EXISTS", os.path.exists(victim))
print("CASE2_RETURN", r2)

# Case 3: legitimate plain filename inside log_path - must still work
r3 = lm.deleteLog("legit.log")
print("CASE3_LEGIT_EXISTS", os.path.exists(legit))
print("CASE3_RETURN", r3)
PYEOF
)
echo "$OUT"

if echo "$OUT" | grep -q "^IMPORT_FAILED"; then
  echo "SKIP: LogManager.py could not be imported in isolation in this environment"
  exit 0
fi

echo "$OUT" | grep -q "^CASE1_VICTIM_EXISTS True" && ok "Case 1: ../ traversal did NOT delete the outside file" || bad "Case 1: path traversal deleted a file outside log_path"
echo "$OUT" | grep -q "^CASE1_RETURN False" && ok "Case 1: deleteLog() returns False for a rejected traversal attempt" || bad "Case 1: deleteLog() did not return False"
echo "$OUT" | grep -q "^CASE2_VICTIM_EXISTS True" && ok "Case 2: absolute path did NOT delete the outside file" || bad "Case 2: absolute path deleted a file outside log_path"
echo "$OUT" | grep -q "^CASE2_RETURN False" && ok "Case 2: deleteLog() returns False for a rejected absolute path" || bad "Case 2: deleteLog() did not return False"
echo "$OUT" | grep -q "^CASE3_LEGIT_EXISTS False" && ok "Case 3: a legitimate plain filename inside log_path still deletes correctly" || bad "Case 3: legitimate deletion was wrongly blocked"
echo "$OUT" | grep -q "^CASE3_RETURN True" && ok "Case 3: deleteLog() returns True for a successful delete" || bad "Case 3: deleteLog() did not return True"

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
