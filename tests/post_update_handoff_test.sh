#!/usr/bin/env bash
# Regression test for the EXACT confirmed-live bug: an OTA launched by
# an OLD perform_update.sh (which has no knowledge of tools/post_update.sh
# at all) must still end up running the NEW post_update.sh, because
# perform_update.sh re-reads post_update.sh fresh from disk AFTER the
# git reset, via `cat tools/post_update.sh | bash -s`, rather than
# inlining the logic (which the live incident proved can never see its
# own post-reset version, since perform_update.sh self-copies to /tmp
# BEFORE the reset).
#
# This test does NOT run a real git reset - it simulates the handoff
# directly: an "old" perform_update.sh-like script (with none of the
# new post-update logic) that still contains the hand-off line, calling
# a post_update.sh placed at the target path AFTER simulating the
# "reset" (a simple file copy standing in for the git operation).
#
# LINUX-ONLY. Confirmed passing on WSL Ubuntu 24.04 this session.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

echo "== Confirm perform_update.sh's hand-off reads post_update.sh via cat (fresh from disk), not by a cached/stale reference =="
grep -q 'cat "\$DEV_REPO_PATH/tools/post_update.sh" | bash -s' "$REPO/addons/tools/perform_update.sh" \
  && ok "perform_update.sh hands off to post_update.sh via cat|bash -s (always fresh from disk)" \
  || bad "perform_update.sh does NOT hand off to post_update.sh the expected way"

echo "== Confirm the hand-off happens AFTER the git reset, not before =="
RESET_LINE=$(grep -n "GM_GIT_AS_OWNER git reset --hard" "$REPO/addons/tools/perform_update.sh" | head -1 | cut -d: -f1)
HANDOFF_LINE=$(grep -n 'cat "\$DEV_REPO_PATH/tools/post_update.sh"' "$REPO/addons/tools/perform_update.sh" | head -1 | cut -d: -f1)
if [[ -n "$RESET_LINE" && -n "$HANDOFF_LINE" && "$HANDOFF_LINE" -gt "$RESET_LINE" ]]; then
  ok "hand-off (line $HANDOFF_LINE) is AFTER the git reset (line $RESET_LINE)"
else
  bad "hand-off is NOT after the git reset (reset=$RESET_LINE, handoff=$HANDOFF_LINE)"
fi

echo "== Confirm perform_update.sh no longer inlines the post-update steps (the confirmed-live bug) =="
if grep -q "_geomaxima_restore_service_states" "$REPO/addons/tools/perform_update.sh"; then
  bad "perform_update.sh still inlines _geomaxima_restore_service_states - this is the exact pattern confirmed live to never execute its own post-reset version"
else
  ok "perform_update.sh does NOT inline the service-restore logic any more"
fi
if grep -q "install_audit_log_access\|install_journald_retention" "$REPO/addons/tools/perform_update.sh"; then
  bad "perform_update.sh still calls install_audit_log_access/install_journald_retention inline - must be in post_update.sh instead"
else
  ok "perform_update.sh does NOT call install_audit_log_access/install_journald_retention inline"
fi

echo "== End-to-end simulation: an OLD perform_update.sh-like script hands off to a post_update.sh dropped in AFTER a simulated reset =="
W="$(mktemp -d /tmp/gm_handoff_test.XXXXXX)"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

mkdir -p "$W/repo/tools"
# "Old" perform_update.sh: has NO knowledge of post_update.sh's
# contents, just the generic hand-off call, exactly as it would be
# immediately after this commit lands (any version from now on,
# regardless of what's inside post_update.sh, uses the same hand-off).
cat > "$W/repo/tools/perform_update.sh" << 'EOF'
#!/usr/bin/env bash
echo "old perform_update.sh: simulating git reset (dropping in new tools/)"
# (the real reset would replace the whole tree - here we just assert
# post_update.sh exists post-"reset", which main.sh below arranges)
echo "old perform_update.sh: handing off to post_update.sh"
if [ -r "$1/tools/post_update.sh" ]; then
    cat "$1/tools/post_update.sh" | bash -s -- "marker-from-new-script"
else
    echo "ERROR: no post_update.sh found"
    exit 1
fi
EOF
# The "new" post_update.sh that only exists AFTER the "reset".
cat > "$W/repo/tools/post_update.sh" << 'EOF'
#!/usr/bin/env bash
echo "NEW post_update.sh ran with marker: $1"
EOF

OUT=$(bash "$W/repo/tools/perform_update.sh" "$W/repo" 2>&1)
echo "$OUT"
echo "$OUT" | grep -q "NEW post_update.sh ran with marker: marker-from-new-script" \
  && ok "end-to-end: old launcher correctly hands off to and runs the new post_update.sh" \
  || bad "end-to-end hand-off simulation failed"

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
