#!/usr/bin/env bash
# Unit-style test for addons/tools/rtkbase_update.sh's generic
# before/after service-state capture+restore logic (the
# "_geomaxima_service_units"/"_geomaxima_restore_service_states"
# functions) - 2026-10-05 archive incident fix: an OTA must preserve
# every service's pre-update active/inactive state exactly, not just
# restart a hand-picked list (the investigation found str2str_file's own
# restore line had been commented out, leaving it stopped for 4+ days).
#
# Mocks `systemctl` entirely (no real systemd interaction) so this runs
# anywhere, including CI, and verifies: a service that was active stays
# active after the OTA; a service that was inactive before stays
# untouched (never force-started); and the full before/after pair is
# written to a temp audit.log in the same JSON-line format
# audit_logger.log_event() uses.
#
# LINUX-ONLY in practice: the `awk` function-extraction pattern and date
# format used (`date -u +"%Y-%m-%dT%H:%M:%S.%6N"`, GNU date's %N) match
# addons/tools/rtkbase_update.sh's own real syntax, which targets
# Debian/Raspberry Pi OS. Confirmed passing 8/8 on WSL Ubuntu 24.04 this
# session; a Windows/Git-Bash run is not a substitute for running this
# on Linux, since the mocked systemctl's own shebang/exec model differs
# there.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

W="$(mktemp -d /tmp/gm_ota_service_state_test.XXXXXX)"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

# Fake systemctl: tracks unit state in a simple file-per-unit under
# $W/units/<unit>.state ("active"/"inactive"), and a file-per-unit under
# $W/units/<unit>.enabled ("enabled"/"disabled"). `start`/`stop` mutate
# state; `is-active`/`is-enabled` read it; `list-unit-files` lists the
# fixed set this test seeds.
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
  start)
    echo "active" > "$UNITS_DIR/$2.state"
    ;;
  stop)
    echo "inactive" > "$UNITS_DIR/$2.state"
    ;;
  restart)
    echo "active" > "$UNITS_DIR/$2.state"
    ;;
  list-unit-files)
    for f in "$UNITS_DIR"/*.state; do
      [[ -e "$f" ]] || continue
      name="$(basename "$f" .state)"
      echo "$name static"
    done
    ;;
  *)
    exit 0
    ;;
esac
MOCKEOF
chmod +x "$W/bin/systemctl"

# Seed 3 fake units: one active, one inactive-by-design, one that an
# OTA's own restarts will "accidentally" stop mid-run.
echo "active" > "$W/units/str2str_tcp.service.state"
echo "enabled" > "$W/units/str2str_tcp.service.enabled"
echo "inactive" > "$W/units/str2str_rtcm_serial.service.state"
echo "disabled" > "$W/units/str2str_rtcm_serial.service.enabled"
echo "active" > "$W/units/str2str_file.service.state"
echo "enabled" > "$W/units/str2str_file.service.enabled"

export GM_TEST_UNITS_DIR="$W/units"
export PATH="$W/bin:$PATH"
export GEOMAXIMA_AUDIT_LOG="$W/audit.log"
export GEOMAXIMA_SERVICE_STATE_FILE="$W/ota_service_state_before_update"

# Extract just the 3 functions under test from rtkbase_update.sh into
# their own sourceable file, so this test exercises the REAL
# implementation, not a reimplementation of it.
awk '/^_geomaxima_audit_log\(\) \{/,/^}/{print} /^_geomaxima_service_units\(\) \{/,/^}/{print} /^_geomaxima_restore_service_states\(\) \{/,/^}/{print}' \
  "$REPO/addons/tools/rtkbase_update.sh" > "$W/functions.sh"
# Also need the two path variables these functions reference.
cat >> "$W/preamble.sh" << EOF
GEOMAXIMA_AUDIT_LOG="$W/audit.log"
EOF
source "$W/preamble.sh"
source "$W/functions.sh"

echo "== Capture before-update state =="
_geomaxima_before_json="["
_geomaxima_first=1
: > "${GEOMAXIMA_SERVICE_STATE_FILE}"
while IFS= read -r unit; do
  [[ -z "${unit}" ]] && continue
  active=$(systemctl is-active "${unit}" 2>/dev/null)
  enabled=$(systemctl is-enabled "${unit}" 2>/dev/null)
  echo "${unit} ${active} ${enabled}" >> "${GEOMAXIMA_SERVICE_STATE_FILE}"
done < <(_geomaxima_service_units)
cat "${GEOMAXIMA_SERVICE_STATE_FILE}"
grep -q "str2str_tcp.service active enabled" "${GEOMAXIMA_SERVICE_STATE_FILE}" && ok "captured str2str_tcp as active/enabled" || bad "did not capture str2str_tcp correctly"
grep -q "str2str_rtcm_serial.service inactive disabled" "${GEOMAXIMA_SERVICE_STATE_FILE}" && ok "captured str2str_rtcm_serial as inactive/disabled" || bad "did not capture str2str_rtcm_serial correctly"

echo "== Simulate the OTA stopping str2str_file as an unrelated side effect =="
systemctl stop str2str_file.service
[[ "$(systemctl is-active str2str_file.service)" == "inactive" ]] && ok "str2str_file is now inactive (simulated OTA side effect)" || bad "mock systemctl stop failed"

echo "== Restore service states =="
_geomaxima_restore_service_states
cat "$W/audit.log" 2>/dev/null

[[ "$(systemctl is-active str2str_file.service)" == "active" ]] && ok "str2str_file restored to active after the OTA" || bad "str2str_file was NOT restored to active"
[[ "$(systemctl is-active str2str_rtcm_serial.service)" == "inactive" ]] && ok "str2str_rtcm_serial (was inactive) stayed inactive - never force-started" || bad "str2str_rtcm_serial was wrongly started"
[[ "$(systemctl is-active str2str_tcp.service)" == "active" ]] && ok "str2str_tcp (already active, untouched) stays active" || bad "str2str_tcp ended up inactive"

grep -q '"event": "after_update"' "$W/audit.log" && ok "after_update event logged to audit.log" || bad "missing after_update audit event"
grep -q 'str2str_file' "$W/audit.log" && ok "str2str_file's before/after state present in audit.log" || bad "str2str_file missing from audit.log"

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
