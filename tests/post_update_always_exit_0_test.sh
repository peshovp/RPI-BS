#!/usr/bin/env bash
# Regression test for the 2026-10-13 review fix: tools/post_update.sh
# must ALWAYS exit 0, regardless of what fails inside it - a second,
# independent line of defense (on top of perform_update.sh's own
# `if cat post_update.sh | bash -s; then ... else ...warn...; fi` wrapper,
# present in BOTH the already-committed 298cedb version that will launch
# the station's very next OTA, and the current repo version) against the
# still-unexplained "exit 3" seen live, and against any future change to
# this script that might otherwise propagate a nonzero exit and abort
# the parent before it reaches the service-state restore/web restart.
#
# This test runs the REAL tools/post_update.sh (not an extracted
# fragment) under several failure scenarios, with sudo/systemctl/python3
# stubbed via PATH so nothing real is touched.
#
# LINUX-ONLY (bash arrays/traps/process substitution). Confirmed passing
# on WSL Ubuntu 24.04 this session.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
W=$(mktemp -d /tmp/gm_post_update_exit0_test.XXXXXX)
cleanup() { rm -rf "$W"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

mkdir -p "$W/bin" "$W/repo/tools"

echo "== Static check: trap 'exit 0' EXIT is registered in the real post_update.sh =="
grep -q "trap 'exit 0' EXIT" "$REPO/addons/tools/post_update.sh" \
  && ok "post_update.sh registers an unconditional exit-0 EXIT trap" \
  || bad "post_update.sh does NOT register the exit-0 EXIT trap"

echo "== Case A: missing required arguments (an internal contract violation) - must still exit 0 =="
OUT=$(bash "$REPO/addons/tools/post_update.sh" 2>&1)
RC=$?
echo "$OUT"
echo "exit code: $RC"
[ "$RC" -eq 0 ] && ok "Case A: exits 0 even with missing required arguments" || bad "Case A: exit code is $RC, expected 0"

echo "== Case B: sudo/install.sh calls fail, systemctl is missing entirely - must still exit 0 and reach the final 'done' line =="
cat > "$W/bin/sudo" << 'EOF'
#!/bin/sh
echo "STUB sudo: failing on purpose"
exit 1
EOF
chmod +x "$W/bin/sudo"
# No systemctl/python3 on PATH at all - _post_update_service_units()'s
# `systemctl list-unit-files` will fail, is-active/is-enabled will fail.
mkdir -p "$W/repo/tools"
cat > "$W/repo/tools/install.sh" << 'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$W/repo/tools/install.sh"

OUT=$(PATH="$W/bin:/usr/bin:/bin" AUDIT_LOG_OVERRIDE="$W/audit.log" bash "$REPO/addons/tools/post_update.sh" "$W/repo" "testuser" "test-run-id" 2>&1)
RC=$?
echo "$OUT"
echo "exit code: $RC"
[ "$RC" -eq 0 ] && ok "Case B: exits 0 even when install.sh/sudo fail and systemctl is unavailable" || bad "Case B: exit code is $RC, expected 0"
echo "$OUT" | grep -q "post_update.sh: done" && ok "Case B: reached the final 'done' line (did not abort early)" || bad "Case B: did not reach the final 'done' line"

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
