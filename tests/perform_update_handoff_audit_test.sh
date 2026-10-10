#!/usr/bin/env bash
# End-to-end regression test closing the gap that let the
# addons/tools/post_update.sh vs tools/post_update.sh path mismatch slip
# through: tests/perform_update_service_restore_test.sh ran
# tools/post_update.sh DIRECTLY, never exercising perform_update.sh's
# own `[ -r "$DEV_REPO_PATH/tools/post_update.sh" ]` lookup or its
# `cat ... | bash -s --` hand-off - so it could not have caught a path
# mismatch between the two files. This test goes through
# perform_update.sh's REAL gm_post_update_handoff() function (extracted
# verbatim, not reimplemented) against the REAL repo tree, and asserts
# the before_update/after_update audit events actually land in
# audit.log as a result - the exact two events confirmed missing from
# the live Topolchane OTA to c3634fd.
#
# LINUX-ONLY (bash, GNU date). Confirmed passing on WSL Ubuntu 24.04
# this session.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
W=$(mktemp -d /tmp/gm_handoff_audit_test.XXXXXX)
cleanup() { rm -rf "$W"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

PYTHON=python3
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "SKIP: no python3 available in this environment"
  exit 0
fi

mkdir -p "$W/bin" "$W/units"

# Stub sudo/systemctl/stat - same pattern used elsewhere in this suite.
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

cat > "$W/bin/sudo" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
chmod +x "$W/bin/sudo"

mkdir -p "$W/fake_repo/tools"
touch "$W/fake_repo/tools/install.sh"
chmod +x "$W/fake_repo/tools/install.sh"
# Real tools/post_update.sh and branch_switch.sh/platform_detect.sh must
# exist at the fake repo's own tools/ path too - this test's whole point
# is to exercise the REAL lookup against a repo layout that mirrors the
# real one, with audit.log/snapshot paths redirected into $W via the
# same sed-substitution technique perform_update_service_restore_test.sh
# already uses (never editing the real file's actual paths).
AUDIT_LOG="$W/audit.log"
SNAPSHOT_PATH="$W/service_state_before.json"
sed \
  -e "s#/var/lib/rtkbase/audit.log#${AUDIT_LOG}#" \
  -e "s#/var/lib/rtkbase/ota/service_state_before.json#${SNAPSHOT_PATH}#" \
  -e "s#/var/lib/rtkbase/\.post_update_service_state#${W}/.post_update_service_state#" \
  "$REPO/tools/post_update.sh" > "$W/fake_repo/tools/post_update.sh"
chmod +x "$W/fake_repo/tools/post_update.sh"
# branch_switch.sh/platform_detect.sh are sourced by post_update.sh -
# copy them in too so the hand-off doesn't warn about missing files
# (not what this test is about, but keeps output clean).
cp "$REPO/tools/branch_switch.sh" "$W/fake_repo/tools/branch_switch.sh" 2>/dev/null || true
cp "$REPO/tools/platform_detect.sh" "$W/fake_repo/tools/platform_detect.sh" 2>/dev/null || true

export PATH="$W/bin:$PATH"
export GM_TEST_UNITS_DIR="$W/units"
export GM_BRANCH_SWITCH_AUDIT_LOG="$AUDIT_LOG"

RUN_ID="test-run-$$"
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

echo "== Extract and run perform_update.sh's REAL gm_post_update_handoff() against the fake repo =="
HANDOFF_SRC=$(sed -n '/^gm_post_update_handoff() {$/,/^}$/p' "$REPO/addons/tools/perform_update.sh")
GM_WARN_SRC=$(sed -n '/^gm_warn() {$/,/^}$/p' "$REPO/addons/tools/perform_update.sh")
GM_AUDIT_SRC=$(sed -n '/^_gm_audit_log() {$/,/^}$/p' "$REPO/addons/tools/perform_update.sh")
GM_JSON_SRC=$(sed -n '/^gm_json_string() {$/,/^}$/p' "$REPO/addons/tools/perform_update.sh")

if [[ -z "$HANDOFF_SRC" ]]; then
  echo "FAIL: could not extract gm_post_update_handoff() from perform_update.sh"
  exit 1
fi

OUT=$(bash -c "
$GM_JSON_SRC
GM_AUDIT_LOG_PATH='$AUDIT_LOG'
$GM_AUDIT_SRC
GM_WARNINGS=()
$GM_WARN_SRC
log_status() { echo \"LOG \$1: \$2\"; }
DEV_REPO_PATH='$W/fake_repo'
REPO_OWNER='testuser'
GEOMAXIMA_RUN_ID='$RUN_ID'
GM_POST_UPDATE_DONE=0
$HANDOFF_SRC
gm_post_update_handoff
" 2>&1)
echo "$OUT"

echo "== Verify =="
echo "$OUT" | grep -q "not found in the updated tree" && bad "perform_update.sh's REAL hand-off reports post_update.sh NOT FOUND - this is the exact live bug reproducing" || ok "perform_update.sh's real hand-off found and ran tools/post_update.sh"
[[ "$(cat "$W/units/str2str_file.service.state")" == "active" ]] && ok "str2str_file.service restored to active via the real end-to-end hand-off" || bad "str2str_file.service NOT restored (end-to-end)"
[[ "$(cat "$W/units/str2str_file.service.enabled")" == "enabled" ]] && ok "str2str_file.service restored to enabled via the real end-to-end hand-off" || bad "str2str_file.service NOT restored enabled (end-to-end)"
grep -q '"event": "before_update"' "$AUDIT_LOG" 2>/dev/null && ok "before_update event landed in audit.log via the REAL perform_update.sh hand-off path" || bad "before_update event MISSING - this is exactly what the live Topolchane OTA showed"
grep -q '"event": "after_update"' "$AUDIT_LOG" 2>/dev/null && ok "after_update event landed in audit.log via the REAL perform_update.sh hand-off path" || bad "after_update event MISSING - this is exactly what the live Topolchane OTA showed"

echo "== Case 2: tools/post_update.sh MISSING from the updated tree - must be a WARNING, not silently treated as success =="
rm -f "$W/fake_repo/tools/post_update.sh"
OUT2=$(bash -c "
$GM_JSON_SRC
GM_AUDIT_LOG_PATH='$AUDIT_LOG'
$GM_AUDIT_SRC
GM_WARNINGS=()
$GM_WARN_SRC
log_status() { echo \"LOG \$1: \$2\"; }
DEV_REPO_PATH='$W/fake_repo'
REPO_OWNER='testuser'
GEOMAXIMA_RUN_ID='$RUN_ID'
GM_POST_UPDATE_DONE=0
$HANDOFF_SRC
gm_post_update_handoff
if [ \"\${#GM_WARNINGS[@]}\" -eq 0 ]; then
    log_status \"success\" \"Update completed successfully\"
else
    echo \"FINAL_STATUS=completed_with_warnings\"
    printf 'WARNING: %s\n' \"\${GM_WARNINGS[@]}\"
fi
" 2>&1)
echo "$OUT2"
echo "$OUT2" | grep -q "not found in the updated tree" && ok "Case 2: the missing-file warning fired" || bad "Case 2: expected the missing-file warning to fire"
echo "$OUT2" | grep -q "^FINAL_STATUS=completed_with_warnings$" && ok "Case 2: final status is completed_with_warnings, not plain success" || bad "Case 2: a missing post_update.sh was NOT reflected in the final status"
echo "$OUT2" | grep -q "LOG success: Update completed successfully" && bad "Case 2: plain 'Update completed successfully' was logged despite the missing file" || ok "Case 2: plain success status was correctly NOT logged"

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
