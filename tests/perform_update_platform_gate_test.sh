#!/usr/bin/env bash
# Regression test for a confirmed-live warning (2026-10-14): the Orange
# Pi 4 Pro (Armbian) OTA to 69487ce reported "raspi-config SPI enable
# failed - continuing anyway" as a WARNING (part of the final
# "completed with warnings" status) even though nothing was actually
# wrong - raspi-config simply doesn't exist on Armbian, by design. The
# SPI-enable step in perform_update.sh is now gated on GM_PLATFORM (from
# tools/platform_detect.sh, sourced directly in perform_update.sh as of
# this fix): runs raspi-config only when GM_PLATFORM=rpi; on any other
# platform it logs a plain INFO "skipped: not a Raspberry Pi", never a
# warning.
#
# This test extracts the REAL gated block (not a hand-written
# reimplementation) via sed and runs it under both GM_PLATFORM=rpi and
# GM_PLATFORM=armbian, confirming raspi-config is only actually invoked
# in the rpi case, and that the armbian case produces NO warning (an
# empty GM_WARNINGS array).
#
# LINUX-ONLY (bash). Confirmed passing on WSL Ubuntu 24.04 this session.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
W=$(mktemp -d /tmp/gm_platform_gate_test.XXXXXX)
cleanup() { rm -rf "$W"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

mkdir -p "$W/bin" "$W/fake_repo/tools"

echo "== Static check: perform_update.sh gates the SPI step on GM_PLATFORM == rpi =="
grep -q 'if \[\[ "\${GM_PLATFORM:-unknown}" == "rpi" \]\]; then' "$REPO/addons/tools/perform_update.sh" \
  && ok "perform_update.sh gates the SPI step on GM_PLATFORM" \
  || bad "perform_update.sh does NOT gate the SPI step on GM_PLATFORM"
grep -q 'not a Raspberry Pi' "$REPO/addons/tools/perform_update.sh" \
  && ok "perform_update.sh logs a plain skip message on non-rpi platforms" \
  || bad "perform_update.sh does not have the expected skip message"

run_spi_block() {
    local platform="$1"
    local raspi_config_calls="$W/raspi_config_calls.$platform"
    rm -f "$raspi_config_calls"
    cat > "$W/bin/raspi-config" << EOF
#!/usr/bin/env bash
echo "raspi-config \$*" >> "$raspi_config_calls"
exit 0
EOF
    chmod +x "$W/bin/raspi-config"
    # Stub sudo too - the real block calls `sudo raspi-config ...`, and
    # without a stub `sudo` would try to prompt for a real password and
    # hang this test indefinitely.
    cat > "$W/bin/sudo" << 'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
    chmod +x "$W/bin/sudo"

    # Fake tools/platform_detect.sh: just sets GM_PLATFORM to whatever
    # this test case needs, without depending on this sandbox's own
    # real hardware (which is neither an rpi nor armbian).
    cat > "$W/fake_repo/tools/platform_detect.sh" << EOF
GM_PLATFORM="$platform"
GM_BOARD="test-board"
GM_ARCH="test-arch"
EOF

    # Extract the EXACT gated block (from the "GeoMaxima - 2026-10-14"
    # comment through the matching fi) - not reimplemented.
    local BLOCK
    BLOCK=$(awk '/^# GeoMaxima - 2026-10-14 review fix: confirmed live on an Orange Pi 4$/{found=1} found{print; if (/^fi$/) {fi_count++; if (fi_count==2) exit}}' "$REPO/addons/tools/perform_update.sh")
    if ! echo "$BLOCK" | grep -q 'GM_PLATFORM'; then
        echo "FAIL: could not extract the platform-gated SPI block from perform_update.sh"
        return 1
    fi

    PATH="$W/bin:$PATH" DEV_REPO_PATH="$W/fake_repo" bash -c "
log_status() { echo \"LOG \$1: \$2\"; }
GM_WARNINGS=()
gm_warn() { GM_WARNINGS+=(\"\$1\"); echo \"WARN: \$1\" >&2; }
DEV_REPO_PATH='$W/fake_repo'
$BLOCK
echo \"WARNINGS_COUNT=\${#GM_WARNINGS[@]}\"
" 2>&1

    echo "---"
    if [[ -f "$raspi_config_calls" ]]; then
        echo "raspi-config was called: $(cat "$raspi_config_calls")"
        return 0
    else
        echo "raspi-config was NOT called"
        return 2
    fi
}

echo "== Case A: GM_PLATFORM=rpi - raspi-config IS invoked, no warning =="
OUT_A=$(run_spi_block rpi)
RC_A=$?
echo "$OUT_A"
[ "$RC_A" -eq 0 ] && ok "Case A: raspi-config was invoked on GM_PLATFORM=rpi" || bad "Case A: raspi-config was NOT invoked on rpi"
echo "$OUT_A" | grep -q "^WARNINGS_COUNT=0$" && ok "Case A: no warnings recorded (raspi-config succeeded)" || bad "Case A: unexpected warning recorded"

echo "== Case B: GM_PLATFORM=armbian - raspi-config is NEVER invoked, plain INFO skip, no warning =="
OUT_B=$(run_spi_block armbian)
RC_B=$?
echo "$OUT_B"
[ "$RC_B" -eq 2 ] && ok "Case B: raspi-config was correctly NOT invoked on GM_PLATFORM=armbian" || bad "Case B: raspi-config was invoked on Armbian - this is the exact live bug"
echo "$OUT_B" | grep -q "skipped: not a Raspberry Pi\|not a Raspberry Pi" && ok "Case B: a plain INFO skip message was logged" || bad "Case B: no skip message found"
echo "$OUT_B" | grep -q "^LOG info:.*not a Raspberry Pi" && ok "Case B: the skip message is logged at INFO level, not as a warning" || bad "Case B: the skip message was not logged as plain info"
echo "$OUT_B" | grep -q "^WARNINGS_COUNT=0$" && ok "Case B: no warnings recorded on Armbian (the exact live noise this fixes)" || bad "Case B: a warning was still recorded on Armbian"

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
