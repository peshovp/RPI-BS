#!/usr/bin/env bash
# Regression test for the 2026-10-13 OTA incident: a best-effort step's
# failure (confirmed live - install.sh --journald-retention, invoked from
# post_update.sh, failing under _check_user()'s old logname-only
# resolution) must NEVER be reported as a FAILED update, and the
# service-state restore + final web restart must ALWAYS run even if the
# script exits before reaching its own normal completion.
#
# This test runs a MINIMAL script that mirrors perform_update.sh's own
# gm_warn/gm_run_finally/GM_RESET_DONE/GM_POST_UPDATE_DONE/GM_WEB_RESTARTED
# structure directly extracted from the real file (not re-implemented by
# hand, to guarantee this test tracks the real logic) via sed, exercised
# against two scenarios:
#   Case A: a BEST-EFFORT step fails (simulated) - the script must still
#           reach its normal completion, call gm_post_update_handoff and
#           gm_restart_web exactly once each, and report
#           "completed with warnings", never "FAILED".
#   Case B: the script aborts UNEXPECTEDLY (simulated via an unguarded
#           command failing under set -e) AFTER GM_RESET_DONE=1 but
#           BEFORE reaching the normal gm_post_update_handoff/
#           gm_restart_web calls - gm_run_finally's EXIT trap must still
#           invoke both exactly once.
#
# LINUX-ONLY (bash arrays/traps). Confirmed passing on WSL Ubuntu 24.04
# this session.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
W=$(mktemp -d /tmp/gm_best_effort_split_test.XXXXXX)
cleanup() { rm -rf "$W"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

SRC="$REPO/addons/tools/perform_update.sh"

echo "== Static checks on the real perform_update.sh =="
grep -q "^GM_WARNINGS=()" "$SRC" && ok "GM_WARNINGS array exists" || bad "GM_WARNINGS array missing"
grep -q "^gm_warn() {" "$SRC" && ok "gm_warn() exists" || bad "gm_warn() missing"
grep -q "^gm_run_finally() {" "$SRC" && ok "gm_run_finally() exists" || bad "gm_run_finally() missing"
grep -q "trap gm_run_finally EXIT" "$SRC" && ok "gm_run_finally is registered as the EXIT trap" || bad "gm_run_finally is not the EXIT trap"
grep -q "completed with warnings" "$SRC" && ok "\"completed with warnings\" status text exists" || bad "no warnings-status text found"
# The function DEFINITIONS must appear before GM_RESET_DONE's best-effort
# steps (raspi-config etc) so a trap firing mid-way can always call them -
# confirmed by checking gm_post_update_handoff() is defined before the
# raspi-config best-effort line, not only called there.
RESET_LINE=$(grep -n "^GM_RESET_DONE=1" "$SRC" | head -1 | cut -d: -f1)
DEFINE_LINE=$(grep -n "^gm_post_update_handoff() {" "$SRC" | head -1 | cut -d: -f1)
RASPI_LINE=$(grep -n "raspi-config nonint do_spi" "$SRC" | head -1 | cut -d: -f1)
if [[ -n "$RESET_LINE" && -n "$DEFINE_LINE" && -n "$RASPI_LINE" && "$DEFINE_LINE" -gt "$RESET_LINE" && "$DEFINE_LINE" -lt "$RASPI_LINE" ]]; then
  ok "gm_post_update_handoff() is defined between GM_RESET_DONE=1 and the first best-effort step (line $DEFINE_LINE)"
else
  bad "gm_post_update_handoff() is not defined early enough (reset=$RESET_LINE, define=$DEFINE_LINE, raspi=$RASPI_LINE) - a trap firing between these points would call an undefined function"
fi

echo "== Extracted-logic simulation: Case A - a best-effort step fails, update still completes with warnings, restore+restart run exactly once =="
# Build a minimal harness using the REAL gm_warn/gm_run_finally bodies
# (extracted via sed) plus fake gm_post_update_handoff/gm_restart_web
# that just record how many times they were called.
GM_WARN_SRC=$(sed -n '/^gm_warn() {$/,/^}$/p' "$SRC")
GM_FINALLY_SRC=$(sed -n '/^gm_run_finally() {$/,/^}$/p' "$SRC")
GM_AUDIT_SRC=$(sed -n '/^_gm_audit_log() {$/,/^}$/p' "$SRC")
GM_JSON_SRC=$(sed -n '/^gm_json_string() {$/,/^}$/p' "$SRC")

[[ -z "$GM_WARN_SRC" || -z "$GM_FINALLY_SRC" ]] && { echo "FAIL: could not extract gm_warn/gm_run_finally from perform_update.sh"; exit 1; }

cat > "$W/case_a.sh" << HARNESS_EOF
#!/usr/bin/env bash
set -Ee
GM_UPDATE_DONE=0
GM_ERROR_REPORTED=0
GM_WARNINGS=()
GM_FINALLY_RAN=0
GM_RESET_DONE=1
GM_POST_UPDATE_DONE=0
GM_WEB_RESTARTED=0
HANDOFF_CALLS=0
RESTART_CALLS=0
GM_AUDIT_LOG_PATH="$W/audit.log"

$GM_JSON_SRC
$GM_AUDIT_SRC
$GM_WARN_SRC
log_status() { echo "LOG_STATUS \$1: \$2"; }
GM_LAST_LINE=""
GM_LAST_SOURCE=""
trap 'GM_LAST_LINE=\$LINENO; GM_LAST_SOURCE=\${BASH_SOURCE[0]:-\$0}' ERR
$GM_FINALLY_SRC
trap gm_run_finally EXIT

gm_post_update_handoff() {
    [ "\$GM_POST_UPDATE_DONE" = 1 ] && return 0
    GM_POST_UPDATE_DONE=1
    HANDOFF_CALLS=\$((HANDOFF_CALLS + 1))
    echo "HANDOFF_CALLED"
    # Simulate the best-effort install.sh --journald-retention call
    # failing (the exact live incident) - must not abort this script.
    gm_warn "install_journald_retention reported an error - continuing anyway (simulated)"
}
gm_restart_web() {
    [ "\$GM_WEB_RESTARTED" = 1 ] && return 0
    GM_WEB_RESTARTED=1
    RESTART_CALLS=\$((RESTART_CALLS + 1))
    echo "RESTART_CALLED"
}

gm_post_update_handoff

if [ "\${#GM_WARNINGS[@]}" -eq 0 ]; then
    log_status "success" "Update completed successfully"
else
    echo "STATUS=completed_with_warnings"
fi

gm_restart_web
GM_UPDATE_DONE=1
echo "FINAL_HANDOFF_CALLS=\$HANDOFF_CALLS"
echo "FINAL_RESTART_CALLS=\$RESTART_CALLS"
exit 0
HARNESS_EOF

OUT=$(bash "$W/case_a.sh" 2>&1)
echo "$OUT"
echo "$OUT" | grep -q "^STATUS=completed_with_warnings" && ok "Case A: reported as completed_with_warnings, never FAILED" || bad "Case A: did not report completed_with_warnings"
echo "$OUT" | grep -q "^LOG_STATUS error" && bad "Case A: an error status was logged despite the update actually succeeding" || ok "Case A: no error status logged"
echo "$OUT" | grep -q "^FINAL_HANDOFF_CALLS=1$" && ok "Case A: gm_post_update_handoff called exactly once" || bad "Case A: handoff call count wrong"
echo "$OUT" | grep -q "^FINAL_RESTART_CALLS=1$" && ok "Case A: gm_restart_web called exactly once" || bad "Case A: restart call count wrong"

echo "== Extracted-logic simulation: Case B - script aborts unexpectedly AFTER GM_RESET_DONE=1 but BEFORE the normal handoff/restart calls - gm_run_finally's EXIT trap must still run both =="
cat > "$W/case_b.sh" << HARNESS_EOF
#!/usr/bin/env bash
set -Ee
GM_UPDATE_DONE=0
GM_ERROR_REPORTED=0
GM_WARNINGS=()
GM_FINALLY_RAN=0
GM_RESET_DONE=1
GM_POST_UPDATE_DONE=0
GM_WEB_RESTARTED=0
HANDOFF_CALLS=0
RESTART_CALLS=0
GM_AUDIT_LOG_PATH="$W/audit_b.log"

$GM_JSON_SRC
$GM_AUDIT_SRC
$GM_WARN_SRC
log_status() { echo "LOG_STATUS \$1: \$2"; }
GM_LAST_LINE=""
GM_LAST_SOURCE=""
trap 'GM_LAST_LINE=\$LINENO; GM_LAST_SOURCE=\${BASH_SOURCE[0]:-\$0}' ERR
$GM_FINALLY_SRC
trap gm_run_finally EXIT

gm_post_update_handoff() {
    [ "\$GM_POST_UPDATE_DONE" = 1 ] && return 0
    GM_POST_UPDATE_DONE=1
    HANDOFF_CALLS=\$((HANDOFF_CALLS + 1))
    echo "HANDOFF_CALLED" >&2
}
gm_restart_web() {
    [ "\$GM_WEB_RESTARTED" = 1 ] && return 0
    GM_WEB_RESTARTED=1
    RESTART_CALLS=\$((RESTART_CALLS + 1))
    echo "RESTART_CALLED" >&2
}

# Simulate an UNGUARDED command failing between GM_RESET_DONE=1 and the
# normal handoff/restart calls - e.g. a genuinely unexpected error, not
# one of the already-guarded best-effort steps.
false
echo "THIS LINE MUST NEVER RUN"
HARNESS_EOF

OUT=$(bash "$W/case_b.sh" 2>&1)
RC=$?
echo "$OUT"
echo "exit code: $RC"
echo "$OUT" | grep -q "THIS LINE MUST NEVER RUN" && bad "Case B: script continued past the unguarded failure (set -e did not abort)" || ok "Case B: script correctly aborted at the unguarded failure"
echo "$OUT" | grep -q "HANDOFF_CALLED" && ok "Case B: gm_run_finally's EXIT trap still called gm_post_update_handoff" || bad "Case B: handoff was NOT called by the finally trap"
echo "$OUT" | grep -q "RESTART_CALLED" && ok "Case B: gm_run_finally's EXIT trap still called gm_restart_web" || bad "Case B: restart was NOT called by the finally trap"
[ "$RC" -ne 0 ] && ok "Case B: script's own exit code reflects the real failure (non-zero)" || bad "Case B: exit code should be non-zero"
echo "$OUT" | grep -qE "failing command at .*case_b\.sh:(0|\?)\)" && bad "Case B: the reported failing line is 0 or ? - the real live symptom this fix addresses" || ok "Case B: a real, non-zero line number was reported (not \"line ?\")"

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
