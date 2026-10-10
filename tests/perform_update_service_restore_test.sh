#!/usr/bin/env bash
# Unit-style test for addons/tools/perform_update.sh's own
# service-state snapshot-read + restore logic (2026-10-07 review fix) -
# this is the GeoMaxima/primary OTA path (git-based), separate from
# addons/tools/rtkbase_update.sh (the older tar-based path, already
# covered by tests/ota_end_to_end_snapshot_test.sh) - it had NO
# service-state preservation at all before this fix.
#
# LINUX-ONLY: mocks `systemctl`, uses GNU date syntax. Confirmed passing
# on WSL Ubuntu 24.04 this session.
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

W="$(mktemp -d /tmp/gm_perform_update_restore_test.XXXXXX)"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

mkdir -p "$W/units" "$W/bin"
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
  enable) echo "enabled" > "$UNITS_DIR/$2.enabled" ;;
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

RUN_ID="test-run-$$"
SNAPSHOT_PATH="$W/service_state_before.json"

echo "== Seed: str2str_file active+enabled; something stops+disables it before this script sees it =="
echo "active" > "$W/units/str2str_file.service.state"
echo "enabled" > "$W/units/str2str_file.service.enabled"

"$PYTHON" - "$REPO" "$SNAPSHOT_PATH" "$RUN_ID" << 'PYEOF'
import sys, importlib.util
repo, snapshot_path, run_id = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("ota_service_snapshot", repo + "/addons/ota_service_snapshot.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.SNAPSHOT_PATH = __import__("pathlib").Path(snapshot_path)
print("write_snapshot:", mod.write_snapshot(run_id=run_id))
PYEOF

echo "inactive" > "$W/units/str2str_file.service.state"
echo "disabled" > "$W/units/str2str_file.service.enabled"

echo "== Extract and run perform_update.sh's own snapshot-read + restore logic =="
cat > "$W/run_restore.sh" << SCRIPT
#!/usr/bin/env bash
set -uo pipefail
GEOMAXIMA_AUDIT_LOG="$W/audit.log"
GEOMAXIMA_SERVICE_STATE_FILE="$W/.ota_service_state_before_update"
GEOMAXIMA_PRE_SHUTDOWN_SNAPSHOT="$SNAPSHOT_PATH"
GEOMAXIMA_SNAPSHOT_MAX_AGE_SECONDS=1800
GEOMAXIMA_RUN_ID="$RUN_ID"
log_status() { echo "LOG[\$1] \$2"; }
SCRIPT
awk '/^_geomaxima_audit_log\(\) \{/,/^}/{print} /^_geomaxima_service_units\(\) \{/,/^}/{print}' "$REPO/addons/tools/perform_update.sh" >> "$W/run_restore.sh"
awk '/^_geomaxima_used_pre_shutdown_snapshot=0/,/^fi$/{print}' "$REPO/addons/tools/perform_update.sh" | head -n -0 >> "$W/run_restore.sh"
awk '/^_geomaxima_restore_service_states\(\) \{/,/^}/{print}' "$REPO/addons/tools/perform_update.sh" >> "$W/run_restore.sh"
echo '_geomaxima_restore_service_states' >> "$W/run_restore.sh"
OUT=$(bash "$W/run_restore.sh" 2>&1)
echo "$OUT"

echo "== Verify =="
[[ "$(cat "$W/units/str2str_file.service.state")" == "active" ]] && ok "str2str_file.service restored to active" || bad "str2str_file.service NOT restored to active"
[[ "$(cat "$W/units/str2str_file.service.enabled")" == "enabled" ]] && ok "str2str_file.service restored to enabled" || bad "str2str_file.service NOT restored to enabled"
echo "$OUT" | grep -q "matched" && ok "pre-shutdown snapshot was used (run_id matched)" || bad "pre-shutdown snapshot was not used"

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
