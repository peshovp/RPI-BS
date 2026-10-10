#!/usr/bin/env bash
# End-to-end test simulating web_app/server.py's real OTA sequence:
#   1. addons/ota_service_snapshot.py writes the pre-shutdown snapshot
#      (while str2str_file.service is still genuinely active)
#   2. something between the snapshot and the update script running
#      stops str2str_file.service (standing in for whatever the real
#      mechanism turns out to be - confirmed NOT rtk.shutdownBase()
#      itself, which never touches systemd services at all, but SOME
#      step in this window did on the real station per d8e817a's own
#      commit message)
#   3. addons/tools/rtkbase_update.sh runs, reads the PRE-shutdown
#      snapshot (not its own later, post-shutdown view), and restores
#      str2str_file.service to active+enabled exactly as it was in step 1
#
# This is the regression test for the actual bug class item C raised:
# a snapshot taken AFTER a shutdown step has already run would record
# the service as "already inactive" and never restore it. This test
# fails if that regresses.
#
# LINUX-ONLY: mocks `systemctl`/`python3`, uses GNU date/awk syntax.
# Verified passing on WSL Ubuntu 24.04 this session.
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

W="$(mktemp -d /tmp/gm_ota_e2e_test.XXXXXX)"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

mkdir -p "$W/units" "$W/bin" "$W/var_lib_rtkbase/ota"
cat > "$W/bin/systemctl" << 'MOCKEOF'
#!/usr/bin/env bash
UNITS_DIR="$GM_TEST_UNITS_DIR"
case "$1" in
  is-active)
    state_file="$UNITS_DIR/$2.state"
    [[ -f "$state_file" ]] && cat "$state_file" || echo "inactive"
    [[ -f "$state_file" ]] && [[ "$(cat "$state_file")" == "active" ]] && exit 0 || exit 3
    ;;
  is-enabled)
    enabled_file="$UNITS_DIR/$2.enabled"
    [[ -f "$enabled_file" ]] && cat "$enabled_file" || echo "disabled"
    [[ -f "$enabled_file" ]] && [[ "$(cat "$enabled_file")" == "enabled" ]] && exit 0 || exit 1
    ;;
  start) echo "active" > "$UNITS_DIR/$2.state" ;;
  stop)  echo "inactive" > "$UNITS_DIR/$2.state" ;;
  restart) echo "active" > "$UNITS_DIR/$2.state" ;;
  list-unit-files)
    for f in "$UNITS_DIR"/*.state; do
      [[ -e "$f" ]] || continue
      echo "$(basename "$f" .state) static"
    done
    ;;
  *) exit 0 ;;
esac
MOCKEOF
chmod +x "$W/bin/systemctl"
export PATH="$W/bin:$PATH"
export GM_TEST_UNITS_DIR="$W/units"

# Seed: str2str_file active+enabled, str2str_tcp active+enabled (control).
echo "active" > "$W/units/str2str_file.service.state"
echo "enabled" > "$W/units/str2str_file.service.enabled"
echo "active" > "$W/units/str2str_tcp.service.state"
echo "enabled" > "$W/units/str2str_tcp.service.enabled"

echo "== Step 1: write the pre-shutdown snapshot (addons/ota_service_snapshot.py) =="
SNAPSHOT_PATH="$W/var_lib_rtkbase/ota/service_state_before.json"
GEOMAXIMA_RUN_ID="test-run-$$"
"$PYTHON" - "$REPO" "$SNAPSHOT_PATH" "$GEOMAXIMA_RUN_ID" << 'PYEOF'
import sys, importlib.util
repo, snapshot_path, run_id = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("ota_service_snapshot", repo + "/addons/ota_service_snapshot.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.SNAPSHOT_PATH = __import__("pathlib").Path(snapshot_path)
ok = mod.write_snapshot(run_id=run_id)
print("write_snapshot() returned:", ok)
PYEOF
cat "$SNAPSHOT_PATH" 2>/dev/null
[[ -f "$SNAPSHOT_PATH" ]] && ok "Step 1: snapshot file written" || bad "Step 1: snapshot file missing"
grep -q '"str2str_file.service"' "$SNAPSHOT_PATH" 2>/dev/null && ok "Step 1: str2str_file.service present in snapshot" || bad "Step 1: str2str_file.service missing from snapshot"

echo "== Step 2: something stops str2str_file.service (simulating the real, unconfirmed mechanism) =="
systemctl stop str2str_file.service
[[ "$(cat "$W/units/str2str_file.service.state")" == "inactive" ]] && ok "Step 2: str2str_file.service is now inactive" || bad "Step 2: mock stop failed"

echo "== Step 3: run rtkbase_update.sh's snapshot-reading preamble + restore, pointed at our fake paths =="
# Extract just the snapshot-read + restore logic (not the whole update
# script, which does a real git/tar update) by sourcing the relevant
# function definitions with the module-level paths overridden.
cat > "$W/run_restore.sh" << SCRIPT
#!/usr/bin/env bash
set -uo pipefail
GEOMAXIMA_AUDIT_LOG="$W/audit.log"
GEOMAXIMA_SERVICE_STATE_FILE="$W/.ota_service_state_before_update"
GEOMAXIMA_PRE_SHUTDOWN_SNAPSHOT="$SNAPSHOT_PATH"
GEOMAXIMA_SNAPSHOT_MAX_AGE_SECONDS=1800
geomaxima_run_id="$GEOMAXIMA_RUN_ID"
SCRIPT
awk '
/^_geomaxima_audit_log\(\) \{/,/^}/{print}
/^_geomaxima_service_units\(\) \{/,/^}/{print}
/^_geomaxima_restore_service_states\(\) \{/,/^}/{print}
' "$REPO/addons/tools/rtkbase_update.sh" >> "$W/run_restore.sh"
# Append the snapshot-read preamble logic (the block between the two
# function definitions and the before_json build, taken verbatim from
# the real script so this test exercises the REAL implementation).
awk '/^_geomaxima_used_pre_shutdown_snapshot=0/,/^_geomaxima_audit_log "before_update"/' "$REPO/addons/tools/rtkbase_update.sh" >> "$W/run_restore.sh"
cat >> "$W/run_restore.sh" << 'SCRIPT'
_geomaxima_restore_service_states
SCRIPT
bash "$W/run_restore.sh"
echo "---audit.log---"
cat "$W/audit.log" 2>/dev/null

echo "== Verify: str2str_file.service restored to active+enabled exactly as before =="
[[ "$(cat "$W/units/str2str_file.service.state")" == "active" ]] && ok "str2str_file.service is active again after restore" || bad "str2str_file.service was NOT restored to active"
[[ "$(cat "$W/units/str2str_file.service.enabled")" == "enabled" ]] && ok "str2str_file.service enabled state unchanged (restore doesn't touch enabled)" || bad "str2str_file.service enabled state changed unexpectedly"
[[ "$(cat "$W/units/str2str_tcp.service.state")" == "active" ]] && ok "control service str2str_tcp still active (untouched)" || bad "control service str2str_tcp wrongly changed"
grep -q "pre_shutdown_snapshot" "$W/audit.log" 2>/dev/null && ok "audit.log records the snapshot source as pre_shutdown_snapshot (not the in-script fallback)" || bad "audit.log does not confirm the pre-shutdown snapshot was used"

echo "== Step 4: a snapshot with the WRONG run_id must be ignored (stale/unrelated-run rejection) =="
echo "active" > "$W/units/str2str_file.service.state"
echo "enabled" > "$W/units/str2str_file.service.enabled"
"$PYTHON" - "$REPO" "$SNAPSHOT_PATH" "different-run-id" << 'PYEOF'
import sys, importlib.util
repo, snapshot_path, run_id = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("ota_service_snapshot", repo + "/addons/ota_service_snapshot.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.SNAPSHOT_PATH = __import__("pathlib").Path(snapshot_path)
mod.write_snapshot(run_id=run_id)
PYEOF
systemctl stop str2str_file.service
cat > "$W/run_restore2.sh" << SCRIPT
#!/usr/bin/env bash
set -uo pipefail
GEOMAXIMA_AUDIT_LOG="$W/audit2.log"
GEOMAXIMA_SERVICE_STATE_FILE="$W/.ota_service_state_before_update2"
GEOMAXIMA_PRE_SHUTDOWN_SNAPSHOT="$SNAPSHOT_PATH"
GEOMAXIMA_SNAPSHOT_MAX_AGE_SECONDS=1800
geomaxima_run_id="$GEOMAXIMA_RUN_ID"
SCRIPT
awk '
/^_geomaxima_audit_log\(\) \{/,/^}/{print}
/^_geomaxima_service_units\(\) \{/,/^}/{print}
/^_geomaxima_restore_service_states\(\) \{/,/^}/{print}
' "$REPO/addons/tools/rtkbase_update.sh" >> "$W/run_restore2.sh"
awk '/^_geomaxima_used_pre_shutdown_snapshot=0/,/^_geomaxima_audit_log "before_update"/' "$REPO/addons/tools/rtkbase_update.sh" >> "$W/run_restore2.sh"
echo '_geomaxima_restore_service_states' >> "$W/run_restore2.sh"
OUT2=$(bash "$W/run_restore2.sh" 2>&1)
echo "$OUT2"
echo "$OUT2" | grep -q "did not match this run" && ok "Step 4: wrong run_id snapshot explicitly rejected" || bad "Step 4: wrong run_id snapshot was NOT rejected"
grep -q '"source": "in_script_fallback"' "$W/audit2.log" 2>/dev/null && ok "Step 4: fell back to in-script snapshot (never trusted the mismatched one)" || bad "Step 4: did not fall back correctly"

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
