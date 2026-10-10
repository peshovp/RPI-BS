#!/usr/bin/env bash
# Integration-style test for tools/install.sh's `--journald-retention`
# flag running successfully with NO --user argument and NO login session
# - the exact live incident scenario (298cedb OTA on a test station,
# invoked from tools/post_update.sh inside a systemd transient unit).
#
# Before the 2026-10-13 fix: `install.sh --journald-retention` always
# called _check_user() unconditionally at the top of main(), which fell
# through to `logname` (empty in that context) and exited 1 - so
# install_journald_retention() never even ran, despite needing no user
# argument at all.
#
# After the fix: _check_user() is only invoked (and only fatal) for flags
# that actually need RTKBASE_USER - --journald-retention alone is not one
# of them, so main() must proceed straight to install_journald_retention()
# regardless of whether a user can be resolved.
#
# Runs the REAL tools/install.sh as a subprocess (not an extracted
# function - this test is about main()'s own argument-gating logic, which
# can't be isolated the way a single function can). systemctl/logname are
# stubbed via PATH; the journald drop-in is written under a temp root via
# a path override environment variable would require patching
# install_journald_retention() itself, which this test deliberately does
# NOT do - instead it only checks that install.sh's own exit code is 0 and
# that install_journald_retention()'s own marker lines appear in its
# output, proving that function was actually reached and ran, which is
# the only thing this incident's fix is about. mkdir/cat-to-/etc are
# themselves stubbed out (overridden via a fake root) so this test does
# not touch the real machine's /etc or /var/log.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
W=$(mktemp -d /tmp/gm_journald_no_user_test.XXXXXX)
cleanup() { rm -rf "$W"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

mkdir -p "$W/bin" "$W/fakeroot/etc/systemd/journald.conf.d" "$W/fakeroot/var/log/journal"

# logname: no login session (the exact live symptom).
cat > "$W/bin/logname" << 'EOF'
#!/bin/sh
echo "logname: no login name" >&2
exit 1
EOF
chmod +x "$W/bin/logname"

# systemd-tmpfiles/systemctl: no-ops, just confirm they'd be called.
cat > "$W/bin/systemd-tmpfiles" << 'EOF'
#!/bin/sh
echo "STUB: systemd-tmpfiles $*"
exit 0
EOF
chmod +x "$W/bin/systemd-tmpfiles"
cat > "$W/bin/systemctl" << 'EOF'
#!/bin/sh
echo "STUB: systemctl $*"
exit 0
EOF
chmod +x "$W/bin/systemctl"

# mkdir/cat real install_journald_retention() writes to /etc and
# /var/log directly (not relative to any override) - redirect via a
# wrapper `mkdir`/shell builtin is not practical to stub for `cat > ...`
# redirection targets, so this test instead copies install.sh and
# rewrites the two absolute paths it writes to, onto this test's fake
# root. This keeps install_journald_retention()'s OWN logic completely
# unmodified - only the two destination paths are substituted - so the
# test still proves the function runs and writes a real drop-in file,
# without touching the real machine's /etc or /var/log.
STUB_INSTALL="$W/install.sh"
sed -e "s#/etc/systemd/journald.conf.d#$W/fakeroot/etc/systemd/journald.conf.d#g" \
    -e "s#/var/log/journal#$W/fakeroot/var/log/journal#g" \
    "$REPO/tools/install.sh" > "$STUB_INSTALL"
chmod +x "$STUB_INSTALL"

OUT=$(PATH="$W/bin:$PATH" bash "$STUB_INSTALL" --journald-retention 2>&1)
RC=$?
echo "$OUT"
echo "exit code: $RC"

[ "$RC" -eq 0 ] && ok "install.sh --journald-retention (no --user, no login session) exits 0" || bad "install.sh --journald-retention should exit 0, got $RC"
echo "$OUT" | grep -q "CONFIGURING PERSISTENT JOURNALD RETENTION" && ok "install_journald_retention() actually ran" || bad "install_journald_retention() never ran"
[ -f "$W/fakeroot/etc/systemd/journald.conf.d/geomaxima-retention.conf" ] && ok "journald drop-in file was written" || bad "journald drop-in file is missing"
echo "$OUT" | grep -qi "logname" && bad "install.sh should never have called the real resolution path that surfaces logname's failure for this flag" || ok "no logname failure surfaced (this flag never needed a resolvable user)"

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
