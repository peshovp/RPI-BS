#!/usr/bin/env bash
# =============================================================================
#  tools/platform_detect.sh
#  Meant to be SOURCED (not executed) by install.sh, tools/install.sh,
#  tools/security_setup.sh, addons/tools/perform_update.sh, and any other
#  GeoMaxima shell script that needs to know what board/OS it is running on.
#
#  Exports, read-only, no side effects (safe to source repeatedly):
#    GM_PLATFORM       one of: rpi | armbian-a733 | armbian | unknown
#    GM_BOARD          human-readable board/model string (best effort)
#    GM_ARCH           uname -m (aarch64 / armv7l / armv6l / x86_64 / ...)
#    GM_CONSOLE_TTYS   space-separated list of tty device names (no "/dev/"
#                       prefix, e.g. "ttyS0 ttyAMA0") that the kernel is using
#                       as a serial console - GNSS auto-detection must never
#                       probe these, since blasting UBX config at a debug
#                       console can look like a hung/broken port and, on some
#                       boards, is the ONLY way to reach a login shell.
#
#  A733/sun60iw2 (Orange Pi 4 Pro+ and any future board sharing that SoC
#  family) is matched by LINUXFAMILY/kernel release string, never by exact
#  board name, so a newer board using the same SoC is detected automatically
#  without a code change here.
# =============================================================================

# GM_ARCH -------------------------------------------------------------------
GM_ARCH="$(uname -m)"

# GM_BOARD (best effort; device-tree model string, present on virtually all
# aarch64 SBCs including Raspberry Pi and Armbian boards) -------------------
GM_BOARD=""
if [[ -r /sys/firmware/devicetree/base/model ]]; then
    # The model string is NUL-terminated; strip trailing NULs/whitespace.
    GM_BOARD="$(tr -d '\0' < /sys/firmware/devicetree/base/model | sed -e 's/[[:space:]]*$//')"
fi

# GM_PLATFORM -----------------------------------------------------------------
GM_PLATFORM="unknown"
if [[ "$GM_BOARD" == *"Raspberry Pi"* ]]; then
    GM_PLATFORM="rpi"
elif [[ -r /etc/armbian-release ]]; then
    # /etc/armbian-release is a simple KEY=VALUE file (BOARD, BOARDFAMILY,
    # LINUXFAMILY, DISTRIBUTION_CODENAME, VERSION, ...). Source it into a
    # private namespace-like prefix by grepping instead of `source`-ing the
    # whole file directly, so an unexpected/malicious value in it can never
    # execute arbitrary shell in our caller's environment.
    _gm_armbian_board="$(grep -E '^BOARD=' /etc/armbian-release 2>/dev/null | cut -d= -f2-)"
    _gm_armbian_family="$(grep -E '^LINUXFAMILY=' /etc/armbian-release 2>/dev/null | cut -d= -f2-)"
    [[ -n "$_gm_armbian_board" ]] && GM_BOARD="$_gm_armbian_board"

    # Match by SoC/family, not exact board name, so future boards sharing
    # the same chip (sun60iw2 = Allwinner A733) are covered automatically.
    # Also check `uname -r` as a fallback in case LINUXFAMILY is ever blank
    # (older Armbian releases have inconsistent /etc/armbian-release content).
    if [[ "$_gm_armbian_family" == *sun60iw2* ]] || [[ "$(uname -r)" == *sun60iw2* ]]; then
        GM_PLATFORM="armbian-a733"
    else
        GM_PLATFORM="armbian"
    fi
    unset _gm_armbian_board _gm_armbian_family
fi

# GM_CONSOLE_TTYS -------------------------------------------------------------
# Two sources, merged and de-duplicated:
#   1. /proc/cmdline's console=ttyXXX,baud arguments (there can be more than
#      one, e.g. a serial console AND a framebuffer console entry).
#   2. /sys/class/tty/console/active, which the kernel maintains at runtime
#      and lists the tty(s) actually backing /dev/console right now.
# Either source alone can miss a console in some bootloader/kernel
# configurations, so both are combined defensively.
_gm_console_ttys=""
if [[ -r /proc/cmdline ]]; then
    _gm_console_ttys+=" $(grep -o 'console=tty[A-Za-z0-9]*' /proc/cmdline 2>/dev/null | sed 's/console=//')"
fi
if [[ -r /sys/class/tty/console/active ]]; then
    _gm_console_ttys+=" $(cat /sys/class/tty/console/active 2>/dev/null)"
fi
GM_CONSOLE_TTYS="$(tr ' ' '\n' <<<"$_gm_console_ttys" | grep -E '^tty' | sort -u | tr '\n' ' ' | sed -e 's/[[:space:]]*$//')"
unset _gm_console_ttys

export GM_PLATFORM GM_BOARD GM_ARCH GM_CONSOLE_TTYS

# GM_DRY_RUN is NOT set/exported here - it is read (not defined) by callers
# such as install.sh's bootloader-overlap and kernel-symlink checks, which
# use it to skip HALTing and instead print what they would have done. It
# defaults to unset/"0" (real run) unless the caller's environment sets it.
