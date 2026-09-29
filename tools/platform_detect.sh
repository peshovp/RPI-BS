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
#    GM_ARCH           dpkg-architecture-derived userland arch (aarch64 /
#                       armv7l / armv6l / x86_64 / ...) - NOT simply
#                       `uname -m`; see the comment where GM_ARCH is set.
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
# NOT simply `uname -m`: Raspberry Pi OS 32-bit on a Pi 3B/4/5 runs a
# 64-bit KERNEL with a 32-bit (armhf) USERLAND - `uname -m` reports
# "aarch64" in that case even though every userspace binary (including any
# RTKLIB build) must be armv7l/armhf, not aarch64. `dpkg --print-architecture`
# reports the actual userland/dpkg architecture and is what determines
# which prebuilt binaries (tools/bin/RTKLIB-2.5.0/<arch>/...) actually run.
# Falls back to `uname -m` on non-Debian-based systems (no dpkg) - none of
# the currently-supported boards hit that fallback, but it keeps this
# script from hard-failing there instead of just guessing wrong.
if command -v dpkg &>/dev/null; then
    case "$(dpkg --print-architecture 2>/dev/null)" in
        arm64)  GM_ARCH="aarch64" ;;
        armhf)
            # dpkg reports "armhf" identically for a Pi Zero/1 (ARMv6) and
            # a Pi 2/3/4 (ARMv7) running Raspberry Pi OS's 32-bit/armhf
            # userland - only `uname -m` distinguishes them (Pi OS armhf is
            # built ARMv6-compatible, so `uname -m` still says "armv6l" on
            # that hardware). Same disambiguation as tools/install.sh's
            # arch_package.
            if [[ "$(uname -m)" == "armv6l" ]]; then
                GM_ARCH="armv6l"
            else
                GM_ARCH="armv7l"
            fi
            ;;
        armel)  GM_ARCH="armv6l" ;;
        amd64)  GM_ARCH="x86_64" ;;
        *)      GM_ARCH="$(uname -m)" ;;
    esac
else
    GM_ARCH="$(uname -m)"
fi

# GM_BOARD (best effort; device-tree model string, present on virtually all
# aarch64 SBCs including Raspberry Pi and Armbian boards) -------------------
GM_BOARD=""
if [[ -r /sys/firmware/devicetree/base/model ]]; then
    # The model string is NUL-terminated; strip trailing NULs/whitespace.
    GM_BOARD="$(tr -d '\0' < /sys/firmware/devicetree/base/model | sed -e 's/[[:space:]]*$//')"
fi

# GM_PLATFORM -----------------------------------------------------------------
# GeoMaxima: GM_TEST_FORCE_PLATFORM is a test-only seam (real boards never
# set it) - lets a test harness (e.g. a generic Ubuntu CI runner faking an
# A733 board via loop devices/fake sysfs) force GM_PLATFORM without needing
# a real device-tree model string or /etc/armbian-release. Only the
# detection ITSELF is skipped when set - GM_CONSOLE_TTYS/gm_has_tty() below
# still run normally either way, unlike an early `return` which would have
# skipped those too.
GM_PLATFORM="unknown"
if [[ -n "${GM_TEST_FORCE_PLATFORM:-}" ]]; then
    GM_PLATFORM="$GM_TEST_FORCE_PLATFORM"
elif [[ "$GM_BOARD" == *"Raspberry Pi"* ]]; then
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

# gm_has_tty(): true if a controlling terminal is actually usable right
# now. GeoMaxima: `[[ -r /dev/tty ]]` is NOT a TTY check - /dev/tty is
# always mode 0666 and readable-by-permission whether or not a controlling
# terminal exists, but OPENING it without one (e.g. under systemd, cron,
# cloud-init, or this project's own geomaxima-firstboot.service) fails
# with ENXIO. Anything that would otherwise `read </dev/tty` or
# `exec ... </dev/tty` must gate on this function first, not on
# `-r /dev/tty`, or it aborts under `set -e` in exactly the non-interactive
# contexts (phase 2 firstboot, OTA) that most need it to degrade
# gracefully instead. Used by install.sh's curl|bash re-exec; available
# for any future interactive prompt anywhere in this project's shell
# scripts (none remain as of this comment - tools/security_setup.sh's
# former UFW enable/disable prompt was removed entirely, see its own
# header comment for why).
gm_has_tty() { ( exec </dev/tty ) 2>/dev/null; }
