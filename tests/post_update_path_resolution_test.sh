#!/usr/bin/env bash
# Regression test for a confirmed-live bug (2026-10-14): post_update.sh
# was created at addons/tools/post_update.sh, but EVERY deployed version
# of perform_update.sh (298cedb, b1c6b83, 8ec046f, c3634fd, and the
# current tree) looks for it at $DEV_REPO_PATH/tools/post_update.sh - the
# plain tools/ path. Confirmed via `git show <hash>:addons/tools/perform_update.sh
# | grep post_update` against every deployed parent. The hand-off had
# therefore NEVER actually run on any station since it was introduced -
# only the web-startup self-heal (a separate code path) saved the
# Topolchane OTA to c3634fd from leaving the station half-fixed.
#
# This test does NOT mock the file's existence or its path - it runs the
# REAL perform_update.sh's actual lookup logic (extracted via sed, not
# hand-copied) against the REAL repository tree, so a future path
# mismatch of this exact kind fails immediately rather than being masked
# by a test that assumes the path is correct.
#
# LINUX-ONLY (bash). Confirmed passing on WSL Ubuntu 24.04 this session.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

echo "== The real tools/post_update.sh actually exists at the path perform_update.sh looks for =="
LOOKUP_LINE=$(grep -n '\-r "\$DEV_REPO_PATH/tools/post_update\.sh"' "$REPO/addons/tools/perform_update.sh" | head -1)
if [[ -z "$LOOKUP_LINE" ]]; then
  bad "could not find perform_update.sh's post_update.sh existence check at all - has the lookup logic changed shape? (grep pattern may need updating, but do not assume the path is fine)"
else
  ok "found perform_update.sh's lookup line: $LOOKUP_LINE"
fi

echo "== End-to-end: run perform_update.sh's REAL lookup logic (extracted, not reimplemented) against the REAL repo tree =="
# Extract the REAL gm_post_update_handoff() function body verbatim (not
# a hand-written reimplementation that could silently drift from the
# actual lookup logic), but replace the `cat ... | bash -s -- ...` hand-
# off itself with a harmless marker before running it - this test is
# about whether the REAL `[ -r "$DEV_REPO_PATH/tools/post_update.sh" ]`
# check finds the file at its real on-disk path, not about actually
# executing post_update.sh's own side effects (sudo/install.sh/systemctl
# calls) inside a test run.
LOOKUP_BLOCK=$(sed -n '/^gm_post_update_handoff() {$/,/^}$/p' "$REPO/addons/tools/perform_update.sh" \
  | sed 's/cat "\$DEV_REPO_PATH\/tools\/post_update\.sh" | bash -s -- "\$DEV_REPO_PATH" "\$REPO_OWNER" "\$GEOMAXIMA_RUN_ID"/echo HANDOFF_WOULD_RUN/')
if [[ -z "$LOOKUP_BLOCK" ]]; then
  echo "FAIL: could not extract gm_post_update_handoff() from perform_update.sh - test cannot proceed"
  exit 1
fi
if ! echo "$LOOKUP_BLOCK" | grep -q "HANDOFF_WOULD_RUN"; then
  echo "FAIL: could not safely neutralize the cat|bash -s hand-off line (its exact text may have changed) - refusing to run the real hand-off inside a test"
  exit 1
fi

OUT=$(bash -c "
gm_warn() { echo \"WARN: \$1\"; }
log_status() { echo \"LOG \$1: \$2\"; }
DEV_REPO_PATH='$REPO'
REPO_OWNER=''
GEOMAXIMA_RUN_ID=''
GM_POST_UPDATE_DONE=0
$LOOKUP_BLOCK
gm_post_update_handoff
" 2>&1)
echo "$OUT"

echo "$OUT" | grep -q "not found in the updated tree" && bad "the REAL lookup logic against the REAL repo tree reports post_update.sh NOT FOUND - this is the exact live bug; tools/post_update.sh must exist at \$DEV_REPO_PATH/tools/post_update.sh" || ok "the real lookup logic finds tools/post_update.sh at the real repo's actual on-disk path"
echo "$OUT" | grep -q "HANDOFF_WOULD_RUN" && ok "confirmed the real hand-off condition would have fired (file found, readable)" || bad "the hand-off condition did not fire even after neutralizing the actual execution - something else is wrong"

echo "== Confirm every historically-deployed perform_update.sh version (298cedb, b1c6b83, 8ec046f, c3634fd) looked up the SAME path - tools/post_update.sh, never addons/tools/post_update.sh =="
for h in 298cedb b1c6b83 8ec046f c3634fd; do
  if git -C "$REPO" cat-file -e "$h" 2>/dev/null; then
    LINE=$(git -C "$REPO" show "$h:addons/tools/perform_update.sh" 2>/dev/null | grep -o '\$DEV_REPO_PATH/tools/post_update\.sh' | head -1)
    if [[ "$LINE" == '$DEV_REPO_PATH/tools/post_update.sh' ]]; then
      ok "$h: looks up \$DEV_REPO_PATH/tools/post_update.sh (the canonical path, now correct)"
    else
      bad "$h: did NOT look up the expected path (got: '$LINE')"
    fi
  else
    echo "  SKIP: commit $h not present in this checkout's history (shallow clone?) - cannot verify"
  fi
done

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
