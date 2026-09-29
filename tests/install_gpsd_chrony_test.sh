#!/usr/bin/env bash
# Unit-style test for tools/install.sh's install_gpsd_chrony(), with
# `dpkg`/`apt-get`/`systemctl` stubbed via PATH - no real packages
# installed, no real services touched.
#
# Confirmed live regression this exists to catch (Orange Pi 4 Pro+ AND
# Raspberry Pi OS, both ship systemd-timesyncd by default): the
# `--no-remove` safety net added across this repo's apt installs
# (c8b6012) broke this specific call - `apt-get install --no-remove
# chrony gpsd` ABORTS with "Packages need to be removed but remove is
# disabled", because chrony Conflicts: time-daemon and systemd-timesyncd
# Provides: time-daemon, so apt must remove systemd-timesyncd to install
# chrony. Fixed by explicitly `apt-get remove`-ing systemd-timesyncd
# FIRST (only when it is actually installed), immediately before the
# --no-remove chrony/gpsd install - this test asserts BOTH halves of that
# ordering:
#   Case A: systemd-timesyncd IS installed -> it is removed, and that
#           removal happens strictly BEFORE the chrony/gpsd install.
#   Case B: systemd-timesyncd is NOT installed (e.g. already replaced by
#           a previous run, or never present) -> no removal is attempted
#           at all, only the chrony/gpsd install runs.
# tools/install.sh is not written to be sourced directly (it
# unconditionally calls `main "$@"` at the bottom) - this test extracts
# just the install_gpsd_chrony() function body via sed and evals it in an
# isolated subshell, rather than modifying that upstream file just for
# testability.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
W=/tmp/gm_gpsd_chrony_test; rm -rf "$W"; mkdir -p "$W/bin"
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
chk() { if eval "$1"; then ok "$2"; else bad "$2"; fi; }

# Extract install_gpsd_chrony()'s body from the real file - if this ever
# fails to find the function, the test fails loudly rather than silently
# testing nothing.
FUNC_SRC=$(sed -n '/^install_gpsd_chrony() {$/,/^}$/p' "$REPO/tools/install.sh")
if [[ -z "$FUNC_SRC" ]]; then
    echo "FAIL: could not extract install_gpsd_chrony() from tools/install.sh - has it been renamed/restructured?"
    exit 1
fi

# Stub dpkg: reports systemd-timesyncd as installed ("ii") or not,
# controlled by $GM_TEST_TIMESYNCD_INSTALLED.
cat > "$W/bin/dpkg" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-l" && "$2" == "systemd-timesyncd" ]]; then
    if [[ "${GM_TEST_TIMESYNCD_INSTALLED:-0}" == "1" ]]; then
        echo "ii  systemd-timesyncd  1:257-1  arm64  minimal time synchronization service"
    else
        echo "dpkg-query: no packages found matching systemd-timesyncd" >&2
        exit 1
    fi
    exit 0
fi
exit 0
EOF
chmod +x "$W/bin/dpkg"

# Stub apt-get: records every "remove" and "install" invocation, in
# order, with its package list, to $GM_TEST_APT_LOG.
cat > "$W/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == "remove" || "$arg" == "install" ]]; then
        action="$arg"
    fi
done
pkgs=()
for arg in "$@"; do
    [[ "$arg" == -* ]] && continue
    [[ "$arg" == "remove" || "$arg" == "install" ]] && continue
    pkgs+=("$arg")
done
echo "${action}: ${pkgs[*]}" >> "$GM_TEST_APT_LOG"
exit 0
EOF
chmod +x "$W/bin/apt-get"

# Stub systemctl: no-op, always succeeds.
cat > "$W/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$W/bin/systemctl"

run_case() {
    # GeoMaxima: install_gpsd_chrony() also writes to real system paths
    # (/etc/chrony/chrony.conf, /lib/systemd/system/*.service, etc.) further
    # down in its body, past the part this test actually verifies (the
    # ordering of the systemd-timesyncd removal vs. the chrony/gpsd
    # install) - those later steps fail loudly (grep/sed/cp errors) in this
    # sandboxed environment since those files don't exist here, which is
    # expected and does not affect this test's assertions (all made from
    # the apt-get log captured before that point). Stderr from those
    # expected failures is discarded here to keep test output readable;
    # `bash -n`/full syntax validity of tools/install.sh is checked
    # separately, not by this test.
    local timesyncd_installed="$1"
    local log="$W/apt_log"; rm -f "$log"
    ( export PATH="$W/bin:$PATH" GM_TEST_APT_LOG="$log" GM_TEST_TIMESYNCD_INSTALLED="$timesyncd_installed"
      APT_TIMEOUT=""
      eval "$FUNC_SRC"
      install_gpsd_chrony ) >/dev/null 2>&1
    cat "$log" 2>/dev/null
}

echo "== Case A: systemd-timesyncd IS installed =="
LOG_A=$(run_case 1)
echo "$LOG_A" | sed 's/^/    /'
chk 'grep -qE "^remove: .*systemd-timesyncd" <<< "$LOG_A"' "systemd-timesyncd is explicitly removed"
chk 'grep -qE "^install: .*chrony" <<< "$LOG_A"' "chrony is installed"
chk 'grep -qE "^install: .*gpsd" <<< "$LOG_A"' "gpsd is installed"
REMOVE_LINE=$(grep -n "^remove:" <<< "$LOG_A" | head -1 | cut -d: -f1)
INSTALL_LINE=$(grep -n "^install:" <<< "$LOG_A" | head -1 | cut -d: -f1)
chk '[[ -n "$REMOVE_LINE" && -n "$INSTALL_LINE" && "$REMOVE_LINE" -lt "$INSTALL_LINE" ]]' "the systemd-timesyncd removal happens BEFORE the chrony/gpsd install"

echo "== Case B: systemd-timesyncd is NOT installed =="
LOG_B=$(run_case 0)
echo "$LOG_B" | sed 's/^/    /'
chk '! grep -q "^remove:" <<< "$LOG_B"' "no removal is attempted when systemd-timesyncd is not installed"
chk 'grep -qE "^install: .*chrony" <<< "$LOG_B"' "chrony is still installed"
chk 'grep -qE "^install: .*gpsd" <<< "$LOG_B"' "gpsd is still installed"

rm -rf "$W"
echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
