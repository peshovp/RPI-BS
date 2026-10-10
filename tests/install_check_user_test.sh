#!/usr/bin/env bash
# Unit-style test for tools/install.sh's _check_user() - 2026-10-13 OTA
# incident fix.
#
# Confirmed live (OTA to commit 298cedb on a test station): a standalone
# `install.sh --journald-retention` call (no --user, run from
# tools/post_update.sh inside a systemd transient unit with no login
# session) hit `_check_user`'s old `logname`-only fallback, which has no
# answer at all in that context ("logname: no login name"), and exited 1
# - aborting install.sh entirely before install_journald_retention() ever
# ran, even though that step doesn't need a user at all.
#
# _check_user()'s new resolution order:
#   1. --user argument (unchanged)
#   2. settings.conf's [general] user= value, resolved relative to this
#      script's own location
#   3. SUDO_USER (if set and not "root")
#   4. fail (return 1), but this is now only fatal for flags that
#      actually need RTKBASE_USER - see install.sh's own call site.
#
# tools/install.sh is not written to be sourced directly (it
# unconditionally calls `main "$@"` at the bottom) - this test extracts
# just the _check_user() function body via sed and evals it in an
# isolated subshell, the same pattern tests/install_gpsd_chrony_test.sh
# already uses.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
W=$(mktemp -d /tmp/gm_check_user_test.XXXXXX)
cleanup() { rm -rf "$W"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

FUNC_SRC=$(sed -n '/^_check_user() {$/,/^}$/p' "$REPO/tools/install.sh")
if [[ -z "$FUNC_SRC" ]]; then
    echo "FAIL: could not extract _check_user() from tools/install.sh - has it been renamed/restructured?"
    exit 1
fi

run_check_user() {
    # Args: $1=ARG_USER value, $2=script dir to actually place a stub
    # install.sh in (so BASH_SOURCE[0] is naturally correct - _check_user
    # is a real function, not something that can fake BASH_SOURCE, which
    # is a readonly bash array), $3=SUDO_USER env value (empty = unset),
    # $4=logname output (simulates a non-interactive context by making
    # logname print nothing and exit nonzero, matching the real failure
    # mode live).
    local arg_user="$1" script_dir="$2" sudo_user="$3" logname_out="$4"
    mkdir -p "$script_dir" "$W/bin"
    # Stub logname: a non-interactive systemd transient unit has none -
    # confirmed live via the exact "logname: no login name" message.
    if [[ -z "$logname_out" ]]; then
        cat > "$W/bin/logname" << 'EOF'
#!/bin/sh
echo "logname: no login name" >&2
exit 1
EOF
    else
        cat > "$W/bin/logname" << EOF
#!/bin/sh
echo "$logname_out"
EOF
    fi
    chmod +x "$W/bin/logname"

    local stub="$script_dir/install.sh"
    {
        echo '#!/usr/bin/env bash'
        echo "$FUNC_SRC"
        echo '_check_user "$1"'
        echo 'rc=$?'
        echo 'if [ $rc -eq 0 ]; then echo "RC=0"; echo "RTKBASE_USER=$RTKBASE_USER"; else echo "RC=1"; fi'
        echo 'exit $rc'
    } > "$stub"
    chmod +x "$stub"

    (
        export PATH="$W/bin:$PATH"
        if [[ -n "$sudo_user" ]]; then
            export SUDO_USER="$sudo_user"
        else
            unset SUDO_USER
        fi
        "$stub" "$arg_user"
    )
}

echo "== Case A: --user argument given - always wins, no logname/settings.conf/SUDO_USER consulted =="
OUT=$(run_check_user "explicit_user" "$W" "" "")
echo "$OUT"
echo "$OUT" | grep -q "^RC=0" && ok "Case A: succeeds" || bad "Case A: should succeed"
echo "$OUT" | grep -q "^RTKBASE_USER=explicit_user" && ok "Case A: RTKBASE_USER is the --user value" || bad "Case A: wrong RTKBASE_USER"

echo "== Case B: no --user, no settings.conf, no SUDO_USER, but logname DOES work (a direct interactive run, not an OTA) - logname is no longer consulted at all per the new explicit resolution order (--user / settings.conf / SUDO_USER / fail), so this must still fail cleanly rather than silently trusting logname =="
mkdir -p "$W/no_settings_conf"
OUT=$(run_check_user "0" "$W/no_settings_conf" "" "aliceuser")
echo "$OUT"
echo "$OUT" | grep -q "^RC=1" && ok "Case B: fails as specified (logname intentionally removed from the resolution order)" || bad "Case B: should fail - logname must no longer be consulted"

echo "== Case C: no --user, settings.conf exists with [general] user='bob' - used ahead of logname =="
# _check_user looks for settings.conf at "<script_dir>/../settings.conf"
# (install.sh lives at <repo>/tools/install.sh, settings.conf at
# <repo>/settings.conf) - so for BASH_SOURCE[0]="$W/with_settings/tools/install.sh"
# the file must be at "$W/with_settings/settings.conf".
mkdir -p "$W/with_settings/tools"
cat > "$W/with_settings/settings.conf" << 'EOF'
[general]
user='bob'
EOF
OUT=$(run_check_user "0" "$W/with_settings/tools" "" "aliceuser")
echo "$OUT"
echo "$OUT" | grep -q "^RC=0" && ok "Case C: succeeds" || bad "Case C: should succeed"
echo "$OUT" | grep -q "^RTKBASE_USER=bob" && ok "Case C: RTKBASE_USER from settings.conf, not logname" || bad "Case C: wrong RTKBASE_USER (expected settings.conf's bob)"
rm -rf "$W/with_settings"

echo "== Case D: no --user, no settings.conf, NO login session (logname fails, confirmed live symptom) but SUDO_USER=carol is set =="
OUT=$(run_check_user "0" "$W/no_settings_conf" "carol" "")
echo "$OUT"
echo "$OUT" | grep -q "^RC=0" && ok "Case D: succeeds via SUDO_USER fallback" || bad "Case D: should succeed via SUDO_USER"
echo "$OUT" | grep -q "^RTKBASE_USER=carol" && ok "Case D: RTKBASE_USER from SUDO_USER" || bad "Case D: wrong RTKBASE_USER"

echo "== Case E: no --user, no settings.conf, no login session, SUDO_USER=root (a root-run sudo, not a real human) - must NOT use root =="
OUT=$(run_check_user "0" "$W/no_settings_conf" "root" "")
echo "$OUT"
echo "$OUT" | grep -q "^RC=1" && ok "Case E: fails cleanly rather than resolving to root" || bad "Case E: should fail (no safe user found)"

echo "== Case F: no --user, no settings.conf, no login session, no SUDO_USER - this is the EXACT live incident scenario (OTA transient unit) =="
OUT=$(run_check_user "0" "$W/no_settings_conf" "" "")
echo "$OUT"
echo "$OUT" | grep -q "^RC=1" && ok "Case F: fails (return 1), does NOT hard-exit the whole script" || bad "Case F: should return 1, not crash"

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
