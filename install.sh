#!/usr/bin/env bash
# OTA update test marker: v2
# =============================================================================
# install.sh - Master installation script for RTKBase on Raspberry Pi OS Trixie
# =============================================================================
# Usage (bootstrap):      curl -fsSL https://raw.githubusercontent.com/peshovp/RPI-BS/main/install.sh | sudo bash
# Usage (already cloned): cd RPI-BS && sudo ./install.sh
#
# MUST be run as root or with sudo.
# =============================================================================

set -euo pipefail

REPO_URL="https://github.com/peshovp/RPI-BS.git"

if [[ -n "${INSTALL_DIR:-}" ]]; then
    : # explicit override, use as-is
elif [[ -n "${SUDO_USER:-}" ]]; then
    SUDO_USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    INSTALL_DIR="${SUDO_USER_HOME:-/root}/RPI-BS"
else
    INSTALL_DIR="${HOME:-/root}/RPI-BS"
fi

log() { echo "$1" >&2; }

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (or using sudo)." >&2
    exit 1
fi

# --- Bootstrap: get a real, single, consistent checkout on disk FIRST ---
# GeoMaxima: previously, `curl | sudo bash` fetched a couple of small helper
# files individually (platform_detect.sh, armbian_kernel_pin.sh) by raw URL
# before the actual clone happened later in the script, then read the rest
# of the helpers from that later clone. That risks version skew between
# "main" at the time of the curl-fetched helpers vs. "main" at the time of
# the later git clone (a push landing in between), and duplicates the
# clone/fetch logic. Fixed by moving the clone to the very first thing this
# script does, then re-exec'ing the SAME install.sh from inside that single
# checkout - everything from this point on (this process and its children)
# reads from one consistent, already-on-disk revision, and there is no more
# curl-by-raw-URL fetching of individual helper files anywhere in this
# script. Under a local checkout (`cd RPI-BS && sudo ./install.sh`), the
# checkout already exists and no clone/exec/re-launch happens at all.
#
# detect_existing_checkout(): true if BASH_SOURCE[0] is a real file that is
# part of an actual RPI-BS checkout. Under `curl | sudo bash`, BASH_SOURCE[0]
# is something like "bash" or "/dev/stdin" - not a real path - so this
# correctly (and silently) fails in that case; it isn't an error condition.
detect_existing_checkout() {
    local src="${BASH_SOURCE[0]}"
    [[ -f "$src" ]] || return 1
    local dir
    dir="$(cd "$(dirname "$src")" && pwd)"
    [[ -f "$dir/tools/security_setup.sh" && -f "$dir/web_app/server.py" ]] || return 1
    echo "$dir"
}

# Clones (or, if already present, fast-forward pulls) the repo into
# INSTALL_DIR. Prints the resolved directory as the ONLY line on stdout so
# callers can safely capture it with $(...); all progress/log messages are
# sent to stderr via log() to avoid polluting that capture.
bootstrap_repo() {
    if ! command -v git &>/dev/null; then
        log "git not found, installing..."
        apt update -qq && apt install -y -qq git || { log "ERROR: failed to install git"; exit 1; }
    fi

    if [[ -d "$INSTALL_DIR/.git" ]]; then
        log "Existing checkout found at $INSTALL_DIR, updating (git pull --ff-only)..."
        # GeoMaxima: warn-and-continue-with-what's-already-there, not exit.
        # Re-running the curl|bash one-liner on a station that has local
        # changes (or a non-ff-only-able history, e.g. after a rebase
        # upstream) must not brick an otherwise-working, already-cloned
        # install just because this particular pull couldn't fast-forward.
        git -C "$INSTALL_DIR" pull --ff-only \
            || log "WARNING: git pull --ff-only failed in $INSTALL_DIR - continuing with the existing checkout as-is (not re-cloning, not exiting)."
    else
        log "No existing checkout found. Cloning $REPO_URL into $INSTALL_DIR..."
        git clone "$REPO_URL" "$INSTALL_DIR" || { log "ERROR: git clone failed"; exit 1; }
    fi

    if [[ -n "${SUDO_USER:-}" ]]; then
        chown -R "$SUDO_USER":"$SUDO_USER" "$INSTALL_DIR" || log "WARNING: chown to $SUDO_USER failed"
    fi

    if [[ ! -f "$INSTALL_DIR/web_app/server.py" || ! -f "$INSTALL_DIR/tools/security_setup.sh" ]]; then
        log "ERROR: $INSTALL_DIR does not look like a valid RPI-BS checkout after bootstrap."
        exit 1
    fi

    echo "$INSTALL_DIR"
}

if SCRIPT_DIR="$(detect_existing_checkout)"; then
    log "Running from existing checkout: $SCRIPT_DIR"
else
    log "No local checkout detected (likely running via curl | sudo bash). Bootstrapping..."
    SCRIPT_DIR="$(bootstrap_repo | tail -1)"
    # Re-exec THIS SAME install.sh, but now as a real file inside the
    # checkout we just cloned, instead of continuing to run as the
    # curl-piped copy. GM_REEXECD guards against a re-exec loop if
    # $SCRIPT_DIR/install.sh were somehow still not a real, detectable
    # checkout (defensive; bootstrap_repo already validates this above).
    if [[ -z "${GM_REEXECD:-}" && -f "$SCRIPT_DIR/install.sh" ]]; then
        log "Re-launching install.sh from the cloned checkout at $SCRIPT_DIR ..."
        export GM_REEXECD=1
        # GeoMaxima: under `curl | sudo bash`, this process's stdin IS the
        # curl-piped script text - whatever of it bash hasn't consumed yet
        # is still sitting there. Without redirecting it, the re-exec'd
        # child would inherit that same stdin and could read leftover
        # script text as if it were interactive input (e.g. into a `read`
        # somewhere downstream). Redirect from /dev/tty when one exists (a
        # real interactive terminal further down the line, e.g. someone
        # running `bash <(curl ...)` at a real console), otherwise
        # /dev/null - never the inherited pipe.
        if [[ -r /dev/tty ]]; then
            exec bash "$SCRIPT_DIR/install.sh" "$@" </dev/tty
        else
            exec bash "$SCRIPT_DIR/install.sh" "$@" </dev/null
        fi
    fi
fi

cd "$SCRIPT_DIR"

# --- Platform detection (Raspberry Pi vs Armbian/A733 vs other) ---
# Now always read locally - SCRIPT_DIR is guaranteed to be a real checkout
# on disk at this point (either pre-existing, or just cloned+re-exec'd into
# above), so there is never a need to fetch this by raw URL.
# shellcheck source=tools/platform_detect.sh
source "$SCRIPT_DIR/tools/platform_detect.sh"
echo "Detected platform: ${GM_PLATFORM:-unknown} (board: ${GM_BOARD:-unknown}, arch: ${GM_ARCH:-$(uname -m)})"

# --- Defensive check: A733 (Orange Pi 4 Pro+ and future same-SoC boards)
# bootloader-write vs. root-partition overlap ---
# GeoMaxima: moved here, BEFORE `apt-get update/upgrade` and the kernel pin
# below - if this ran after the upgrade (as an earlier version of this
# check did) and a linux-u-boot-* package slipped through despite the pin,
# the superblock corruption would already have happened by the time this
# check ran. This check itself never installs/upgrades anything, so
# running it this early has no downside.
#
# HALTS (does not just warn) when it detects an overlap, since every U-Boot
# write from this point on - including a routine `apt upgrade` of
# linux-u-boot-* - would silently overwrite the ext4 superblock and brick
# the board at next reboot. Confirmed live on an Orange Pi 4 Pro+: armbian-
# install had created the root partition starting at 16 MiB (sector 32768)
# instead of the official image's 32 MiB (sector 65536), which
# /usr/lib/u-boot/platform_install.sh's boot_package.fex write (at
# seek=16400K) overlaps.
#
# The check itself runs for the root partition regardless of whether it is
# on SD or eMMC - the overlap is purely a matter of partition geometry vs.
# the bootloader's fixed write offset, and applies identically either way.
# /sys/block/mmcblkN/device/type ("MMC" vs "SD") is used ONLY to phrase the
# message/recommendation below (root already on eMMC gets a different fix
# than root still on SD), never to decide whether to run the check - NOT
# /sys/block/*/removable, which is unreliable on mmc hosts (SD cards often
# report 0/non-removable there too). This matches tools/emmc-install-opi4pro.sh's
# own detection and was verified live on an Orange Pi 4 Pro+ (mmcblk0 =
# MMC/eMMC, mmcblk1 = SD).
# GM_DRY_RUN=1 prints the check's verdict without exiting, for CI.
if [[ "${GM_PLATFORM:-}" == "armbian-a733" ]]; then
    GM_PLATFORM_INSTALL_SCRIPT="/usr/lib/u-boot/platform_install.sh"
    # `|| true`: under set -euo pipefail, `ls -d ... | head -1` with no
    # match makes `ls` exit non-zero, which without this would exit the
    # WHOLE SCRIPT here rather than just leaving GM_UBOOT_DIR empty (the
    # intended, handled case a few lines down).
    GM_UBOOT_DIR="$(ls -d /usr/lib/linux-u-boot-* 2>/dev/null | head -1 || true)"
    if [[ -f "$GM_PLATFORM_INSTALL_SCRIPT" && -n "$GM_UBOOT_DIR" && -f "$GM_UBOOT_DIR/boot_package.fex" ]]; then
        GM_BP_SEEK_K="$(grep -oP 'boot_package\.fex.*bs=1k seek=\K[0-9]+' "$GM_PLATFORM_INSTALL_SCRIPT" | head -1 || true)"
        if [[ -z "$GM_BP_SEEK_K" ]]; then
            GM_BP_SEEK_K=16400
            echo "WARNING: could not parse boot_package.fex seek= from $GM_PLATFORM_INSTALL_SCRIPT - assuming 16400K (the value confirmed live on an Orange Pi 4 Pro+)." >&2
        fi
        GM_BP_SIZE_K=$(( ( $(stat -c%s "$GM_UBOOT_DIR/boot_package.fex") + 1023 ) / 1024 ))
        GM_BP_END_K=$(( GM_BP_SEEK_K + GM_BP_SIZE_K ))

        GM_ROOT_SOURCE="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
        GM_ROOT_DISK_NAME="$(lsblk -no PKNAME "$GM_ROOT_SOURCE" 2>/dev/null || true)"
        GM_ROOT_PART_NAME="$(basename "$GM_ROOT_SOURCE" 2>/dev/null || true)"
        # device/type is read only for the recommendation text below - it
        # never gates whether the size comparison itself runs.
        GM_ROOT_DEVICE_TYPE=""
        [[ -n "$GM_ROOT_DISK_NAME" && -f "/sys/block/${GM_ROOT_DISK_NAME}/device/type" ]] \
            && GM_ROOT_DEVICE_TYPE="$(cat "/sys/block/${GM_ROOT_DISK_NAME}/device/type" 2>/dev/null || true)"
        if [[ -n "$GM_ROOT_DISK_NAME" && -f "/sys/block/${GM_ROOT_DISK_NAME}/${GM_ROOT_PART_NAME}/start" ]]; then
            GM_ROOT_PART_START_SECTORS="$(cat "/sys/block/${GM_ROOT_DISK_NAME}/${GM_ROOT_PART_NAME}/start" 2>/dev/null || echo 0)"
            GM_ROOT_PART_START_K=$(( GM_ROOT_PART_START_SECTORS / 2 ))
            if (( GM_BP_END_K >= GM_ROOT_PART_START_K )); then
                echo "ERROR: the U-Boot bootloader write range (${GM_BP_SEEK_K}K-${GM_BP_END_K}K) overlaps this" >&2
                echo "board's root partition, which starts at ${GM_ROOT_PART_START_K}K on /dev/${GM_ROOT_DISK_NAME} (device/type: ${GM_ROOT_DEVICE_TYPE:-unknown})." >&2
                echo "Every future U-Boot write (including a routine 'apt upgrade' of linux-u-boot-*)" >&2
                echo "would silently corrupt the root filesystem's superblock and brick this board at" >&2
                echo "the next reboot. This is a known armbian-install partition-layout bug on this" >&2
                echo "board (confirmed live on an Orange Pi 4 Pro+)." >&2
                echo "This script will NOT modify partitions/bootloader automatically. Instead:" >&2
                if [[ "$GM_ROOT_DEVICE_TYPE" == "MMC" ]]; then
                    echo "Root is already on eMMC (/dev/${GM_ROOT_DISK_NAME}) with a bad partition layout." >&2
                    echo "Boot this board from an SD card instead, then run" >&2
                    echo "tools/emmc-install-opi4pro.sh from there to re-create the eMMC root partition" >&2
                    echo "at the correct offset (32 MiB / sector 65536) and copy the system back onto it." >&2
                else
                    echo "  1. Boot this board from an SD card (if not already)." >&2
                    echo "  2. Run tools/emmc-install-opi4pro.sh, which creates a correctly-placed root" >&2
                    echo "     partition (32 MiB / sector 65536) on eMMC and copies the system there." >&2
                    echo "  3. Remove the SD card and reboot from eMMC, then re-run this installer." >&2
                fi
                if [[ "${GM_DRY_RUN:-0}" == "1" ]]; then
                    echo "GM_DRY_RUN=1: would have halted here instead of exiting." >&2
                else
                    exit 1
                fi
            else
                echo "Verified: bootloader write range (${GM_BP_SEEK_K}K-${GM_BP_END_K}K) does not overlap the root partition (starts at ${GM_ROOT_PART_START_K}K) - safe to continue." >&2
            fi
        else
            echo "WARNING: could not read the root partition's start offset from sysfs - skipping bootloader-overlap check. Verify manually before rebooting: compare 'cat /sys/block/${GM_ROOT_DISK_NAME:-<disk>}/${GM_ROOT_PART_NAME:-<part>}/start' against the seek= value in $GM_PLATFORM_INSTALL_SCRIPT." >&2
        fi
    fi
fi

echo "============================================================================"
echo "STAGE 1/5: System Update & Prerequisites"
echo "============================================================================"
export DEBIAN_FRONTEND=noninteractive

# --- Armbian-only: pin out Debian-origin kernel packages BEFORE any apt
# upgrade, so a Debian/RT kernel can never get installed alongside this
# board's vendor kernel. See tools/armbian_kernel_pin.sh for the full
# "why" (confirmed-live boot-breaking bug) and why apt-mark hold alone is
# not sufficient. Must run before `apt-get upgrade` on the next line.
if [[ "${GM_PLATFORM:-}" == armbian* ]]; then
    # shellcheck source=tools/armbian_kernel_pin.sh
    source "$SCRIPT_DIR/tools/armbian_kernel_pin.sh"
    geomaxima_apply_armbian_kernel_pin
fi

apt-get update -qq
apt-get upgrade -y -qq

# --- Defensive check: PREEMPT_RT kernel / boot-symlink consistency ---
# On Armbian (and other non-Raspberry-Pi-OS boards using Debian's generic
# kernel package mechanism), installing a linux-image-*-rt-arm64 package
# alongside the board's vendor kernel is a known hazard: the RT kernel's
# postinst updates the /boot/uInitrd symlink to point at itself, but does
# NOT update /boot/Image or /boot/dtb, which keep pointing at the vendor
# kernel (the one with the correct SoC drivers/device-tree). The result is
# U-Boot loading a vendor kernel with an RT initrd - an incompatible
# combination that causes a full boot failure. Confirmed live on an Orange
# Pi 4 Pro station (Allwinner A733, Armbian vendor kernel
# 6.6.98-vendor-sun60iw2) after linux-image-6.12.107+deb13-rt-arm64 ended
# up installed alongside it.
# RTKBase does not require PREEMPT_RT for GNSS processing - this check does
# not assert why an RT kernel is present, only that if one is, /boot/Image,
# /boot/dtb, and /boot/uInitrd must all resolve to the SAME kernel version
# before rebooting.
#
# GeoMaxima: factored into a function because it must run TWICE - once here
# (early, before this script installs/upgrades anything further) and once
# again at the very end of this script (STAGE 5), since tools/install.sh
# and security_setup.sh both install packages that could themselves pull in
# a kernel package. A mismatch caught only at the START would miss one
# introduced by this script's OWN later steps - the end-of-script call is
# the one that actually protects the next reboot.
#
# On Armbian these are symlinks to version-suffixed real files, e.g.
# "uInitrd -> uInitrd-6.6.98-vendor-sun60iw2", "Image -> vmlinuz-<ver>",
# "dtb -> dtb-<ver>" - comparing the version suffix via readlink is simple
# and sufficient; no need to parse mkimage/FIT image headers. `readlink`
# can return either a bare filename or an absolute path (e.g.
# "/boot/vmlinuz-<ver>") depending on how the symlink target was written -
# basename is applied FIRST, before stripping the "<prefix>-" via sed, so
# an absolute-path target is never mistaken for a version mismatch purely
# because of its leading directory component.
# GM_DRY_RUN=1 prints the check's verdict without exiting, for CI.
#
# The three-way symlink comparison itself runs on ANY platform whenever
# all three symlinks exist (not gated on an RT package being installed at
# all - Armbian boards can end up with a kernel-symlink mismatch from other
# causes too, e.g. an interrupted OTA of the vendor kernel package itself).
# The RT-package-installed warning below is a SEPARATE, independent
# message - it is not a precondition for running the symlink comparison,
# it is just additional context printed alongside it when applicable. An
# RT package being merely INSTALLED is not itself fatal (it may not be the
# one actually pointed to by the boot symlinks yet). What DOES halt is an
# ACTUAL mismatch between /boot/Image, /boot/dtb, and /boot/uInitrd right
# now, since the very next reboot would then fail to boot.
#
# $1 (optional): a short label identifying which call site this is, used
# only to phrase the halt message appropriately ("do not reboot" makes
# sense at the end of the script; at the start, nothing has run yet so
# there is nothing to warn against rebooting away from).
geomaxima_check_kernel_symlink_consistency() {
    local call_site="${1:-early}"

    if dpkg -l 2>/dev/null | grep -q -- '-rt-arm64'; then
        echo "WARNING: a PREEMPT_RT (rt-arm64) kernel package is installed on this system." >&2
        echo "On Armbian/non-Raspberry-Pi-OS boards this can desync the /boot/Image, /boot/dtb," >&2
        echo "and /boot/uInitrd symlinks (each may end up pointing at a DIFFERENT kernel after" >&2
        echo "the RT kernel's postinst runs), which causes a hard boot failure at next reboot." >&2
        echo "RTKBase does not require PREEMPT_RT for GNSS processing." >&2
    fi

    if [[ -L /boot/Image && -L /boot/dtb && -L /boot/uInitrd ]]; then
        local img_ver dtb_ver initrd_ver
        img_ver="$(basename "$(readlink /boot/Image 2>/dev/null)" | sed -E 's/^[a-zA-Z]+-//')"
        dtb_ver="$(basename "$(readlink /boot/dtb 2>/dev/null)" | sed -E 's/^[a-zA-Z]+-//')"
        initrd_ver="$(basename "$(readlink /boot/uInitrd 2>/dev/null)" | sed -E 's/^[a-zA-Z]+-//')"
        if [[ -n "$img_ver" && -n "$dtb_ver" && -n "$initrd_ver" ]] \
            && ! [[ "$img_ver" == "$dtb_ver" && "$dtb_ver" == "$initrd_ver" ]]; then
            echo "ERROR: /boot/Image, /boot/dtb, and /boot/uInitrd point at DIFFERENT kernel versions:" >&2
            echo "  /boot/Image   -> $(readlink /boot/Image)" >&2
            echo "  /boot/dtb     -> $(readlink /boot/dtb)" >&2
            echo "  /boot/uInitrd -> $(readlink /boot/uInitrd)" >&2
            if [[ "$call_site" == "end" ]]; then
                echo "DO NOT REBOOT this board in its current state - it would very likely fail to" >&2
                echo "boot (confirmed live on an Orange Pi 4 Pro+ in exactly this state)." >&2
            else
                echo "Rebooting right now would very likely fail to boot (confirmed live on an" >&2
                echo "Orange Pi 4 Pro+ in exactly this state)." >&2
            fi
            echo "This script will NOT repoint these symlinks automatically - fix manually (make" >&2
            echo "all three point at the same, working kernel version) before rebooting." >&2
            if [[ "${GM_DRY_RUN:-0}" == "1" ]]; then
                echo "GM_DRY_RUN=1: would have halted here instead of exiting." >&2
                return 0
            fi
            exit 1
        else
            echo "Verified /boot/Image, /boot/dtb, and /boot/uInitrd currently point at the same kernel version - safe to continue." >&2
        fi
    elif dpkg -l 2>/dev/null | grep -q -- '-rt-arm64'; then
        echo "Before rebooting, verify all three point at the SAME kernel version:" >&2
        echo "  ls -la /boot/Image /boot/dtb /boot/uInitrd" >&2
        echo "This script will NOT modify these symlinks automatically - fix manually if inconsistent." >&2
    fi
}

geomaxima_check_kernel_symlink_consistency early

# --- Defensive check: root filesystem not resized to full disk capacity ---
# Warning-only, never modifies anything. Armbian images can leave the root
# partition/filesystem at its pre-resize (first-boot) size if the standard
# first-boot resize service never ran or was interrupted - the disk reports its
# full physical capacity but df shows only the original small image size.
# This check compares df's view of the root filesystem against the physical size
# of the underlying disk; it never calls resize2fs/growpart/parted itself.
ROOT_SOURCE="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
if [[ -n "$ROOT_SOURCE" ]]; then
    ROOT_DISK="$(lsblk -no PKNAME "$ROOT_SOURCE" 2>/dev/null || true)"
    if [[ -n "$ROOT_DISK" ]]; then
        DISK_BYTES="$(blockdev --getsize64 "/dev/$ROOT_DISK" 2>/dev/null || echo 0)"
        ROOT_BYTES="$(df -B1 --output=size / 2>/dev/null | tail -1 | tr -d ' ' || echo 0)"
        if [[ "$DISK_BYTES" -gt 0 && "$ROOT_BYTES" -gt 0 ]]; then
            # Integer percentage: (ROOT_BYTES * 100) / DISK_BYTES
            ROOT_PCT=$(( ROOT_BYTES * 100 / DISK_BYTES ))
            if [[ "$ROOT_PCT" -lt 50 ]]; then
                echo "WARNING: root filesystem (/) is only ${ROOT_PCT}% of the physical disk size" >&2
                echo "(/dev/$ROOT_DISK, $((DISK_BYTES / 1024 / 1024 / 1024))GB total)." >&2
                echo "This looks like the Armbian first-boot filesystem resize never ran." >&2
                echo "This script will NOT resize the filesystem automatically." >&2
                echo "On Armbian boards, run 'sudo armbian-config' -> System -> Resize, then reboot," >&2
                echo "before continuing, to reclaim the full disk capacity." >&2
            fi
        fi
    fi
fi

apt-get install -y -qq curl git ca-certificates wireguard wireguard-tools openresolv fonts-dejavu-core

# --- DNS resolver resilience: DHCP-provided nameserver stays primary,
# 8.8.8.8/1.1.1.1 added as fallback only ---
# Confirmed live on BaseStation: DNS resolution to both
# igs.gnsswhu.cn (WHU PPP product server) and
# github.com (OTA git fetch) intermittently failed with only a single
# upstream nameserver configured (in that case, DHCP-supplied 8.8.8.8 via
# resolvconf - a single resolver is not resilient enough for either
# lookup). Idempotent and warning-only: detects whichever resolver stack
# is actually active (systemd-resolved, then NetworkManager, then
# dhcpcd/resolvconf, in that priority order, matching this script's
# raspi-config/armbian-config detect-and-degrade pattern above) and adds
# 8.8.8.8/1.1.1.1 as FALLBACK entries only - it never removes or reorders
# the DHCP-provided nameserver, which always stays first/primary. Skips
# (with a warning, not a hard failure) if no supported stack is found,
# since this station's GNSS/RTCM functions do not depend on it.
#
# Verification on a live station after this runs:
#   resolvectl status   (systemd-resolved: shows DNS Servers incl. fallback)
#   cat /etc/resolv.conf (dhcpcd/resolvconf: shows all nameserver lines in order)
#   nmcli dev show <iface> | grep DNS   (NetworkManager)
if command -v resolvectl &>/dev/null && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    RESOLVED_DROPIN_DIR="/etc/systemd/resolved.conf.d"
    RESOLVED_DROPIN="$RESOLVED_DROPIN_DIR/90-geomaxima-fallback-dns.conf"
    if [ -f "$RESOLVED_DROPIN" ]; then
        echo "✓ systemd-resolved fallback DNS drop-in already present at $RESOLVED_DROPIN - skipping."
    else
        mkdir -p "$RESOLVED_DROPIN_DIR"
        cat > "$RESOLVED_DROPIN" <<'EOF'
# Added by RPI-BS install.sh - DNS resilience fallback.
# DHCP-provided DNS (from the router) remains primary automatically -
# this only ADDS fallback resolvers, used when the primary one is
# unreachable/times out, per systemd-resolved's own FallbackDNS semantics.
[Resolve]
FallbackDNS=8.8.8.8 1.1.1.1
EOF
        systemctl reload-or-restart systemd-resolved 2>/dev/null \
            || echo "WARNING: failed to reload systemd-resolved after writing $RESOLVED_DROPIN - fallback DNS will apply after next restart/reboot." >&2
        echo "✓ systemd-resolved fallback DNS (8.8.8.8, 1.1.1.1) configured via $RESOLVED_DROPIN."
    fi
elif command -v nmcli &>/dev/null && systemctl is-active --quiet NetworkManager 2>/dev/null; then
    NM_ACTIVE_CONN="$(nmcli -t -f NAME connection show --active 2>/dev/null | head -1)"
    if [ -z "$NM_ACTIVE_CONN" ]; then
        echo "WARNING: NetworkManager is active but no active connection was found - skipping fallback DNS setup." >&2
    else
        NM_CURRENT_DNS="$(nmcli -g ipv4.dns connection show "$NM_ACTIVE_CONN" 2>/dev/null)"
        if [[ "$NM_CURRENT_DNS" == *"8.8.8.8"* && "$NM_CURRENT_DNS" == *"1.1.1.1"* ]]; then
            echo "✓ NetworkManager connection '$NM_ACTIVE_CONN' already has fallback DNS configured - skipping."
        else
            # ipv4.dns REPLACES the DHCP-supplied resolver list unless
            # ipv4.ignore-auto-dns stays "no" (default) - with that default,
            # NetworkManager appends these to (not instead of) the
            # DHCP-provided servers, which is exactly the desired
            # primary-then-fallback behavior.
            if nmcli connection modify "$NM_ACTIVE_CONN" +ipv4.dns "8.8.8.8" +ipv4.dns "1.1.1.1" 2>/dev/null \
                && nmcli connection up "$NM_ACTIVE_CONN" &>/dev/null; then
                echo "✓ NetworkManager fallback DNS (8.8.8.8, 1.1.1.1) added to connection '$NM_ACTIVE_CONN'."
            else
                echo "WARNING: failed to configure NetworkManager fallback DNS on '$NM_ACTIVE_CONN' - continuing anyway." >&2
            fi
        fi
    fi
elif command -v resolvconf &>/dev/null; then
    # openresolv (already installed above for wg-quick) - its own
    # documented mechanism for adding permanent extra nameserver lines is
    # /etc/resolvconf/resolv.conf.d/tail, appended to the END of the
    # generated /etc/resolv.conf regardless of which interface supplied
    # the DHCP nameserver, which glibc's resolver tries first/primary
    # since it appears earlier in the file.
    RESOLVCONF_TAIL_DIR="/etc/resolvconf/resolv.conf.d"
    RESOLVCONF_TAIL="$RESOLVCONF_TAIL_DIR/tail"
    if [ -f "$RESOLVCONF_TAIL" ] && grep -q "8.8.8.8" "$RESOLVCONF_TAIL" && grep -q "1.1.1.1" "$RESOLVCONF_TAIL"; then
        echo "✓ resolvconf fallback DNS tail already present at $RESOLVCONF_TAIL - skipping."
    else
        mkdir -p "$RESOLVCONF_TAIL_DIR"
        {
            echo "# Added by RPI-BS install.sh - DNS resilience fallback."
            echo "# DHCP-provided nameserver lines (added by resolvconf ABOVE this tail"
            echo "# file's content) remain primary; these are fallback only."
            echo "nameserver 8.8.8.8"
            echo "nameserver 1.1.1.1"
        } > "$RESOLVCONF_TAIL"
        resolvconf -u 2>/dev/null \
            || echo "WARNING: 'resolvconf -u' failed after writing $RESOLVCONF_TAIL - fallback DNS will apply after next network restart/reboot." >&2
        echo "✓ resolvconf fallback DNS (8.8.8.8, 1.1.1.1) configured via $RESOLVCONF_TAIL."
    fi
else
    echo "WARNING: no supported DNS resolver stack found (systemd-resolved/NetworkManager/resolvconf) - skipping fallback DNS setup. This does not affect RTKBase's own RTCM/GNSS functions." >&2
fi

if command -v raspi-config &>/dev/null; then
    raspi-config nonint do_spi 0
elif command -v armbian-config &>/dev/null; then
    echo "WARNING: raspi-config not found (non-Raspberry-Pi-OS board detected)." >&2
    echo "Armbian detected - SPI must be enabled manually via 'armbian-config' (System -> Hardware) if this station's GNSS receiver uses SPI, not UART/USB." >&2
else
    echo "WARNING: neither raspi-config nor armbian-config found - skipping SPI enable step. If this station's GNSS receiver requires SPI, enable it manually for your platform." >&2
fi
echo "System packages updated. curl, git, and ca-certificates confirmed installed."

# GeoMaxima: bootstrap (clone-or-pull + cd, and the curl|bash re-exec) now
# happens once, at the very top of this script - see the comment there.
# SCRIPT_DIR is already set and we are already inside it.

# --- 1. Banner ---
echo "============================================================================"
echo "          RTKBase Master Installation Script"
echo "============================================================================"
echo "This script performs a full, clean installation of RTKBase on Raspberry Pi OS Trixie."
echo "WARNING: This process requires root privileges and will modify system files."
echo ""

# --- 2. Security setup (interactive UFW confirmation happens inside) ---
echo "============================================================================"
echo "STAGE 2/5: Running Security Setup (tools/security_setup.sh)"
echo "============================================================================"
echo "NOTE: This script will prompt you for confirmation (e.g., enabling UFW)."

chmod +x tools/security_setup.sh
./tools/security_setup.sh

# --- 3. Upstream RTKBase base installation ---
# tools/install.sh expects to run from a parent directory and clones/downloads
# RTKBase into a fresh "rtkbase/" subfolder (rtkbase_path="$(pwd)/rtkbase").
# This repo checkout already IS that "rtkbase" folder, so we point a
# "rtkbase" symlink at ourselves before invoking it -- this lets tools/install.sh's
# own checks (e.g. "-d rtkbase", "rtkbase/.git") resolve to this checkout
# instead of cloning a nested duplicate copy.
# tools/install.sh creates the venv (at "$(pwd)/rtkbase/venv" -> here, "venv/"),
# installs web_app/requirements.txt, and copies/activates the systemd units
# itself (it calls tools/copy_unit.sh internally) -- do not duplicate those steps here.
echo ""
echo "============================================================================"
echo "STAGE 3/5: Running Upstream RTKBase Base Installation (tools/install.sh)"
echo "============================================================================"

if [ ! -L "rtkbase" ]; then
    ln -s . rtkbase
fi

chmod +x tools/install.sh tools/copy_unit.sh 2>/dev/null || true
chmod +x tools/install_polkit_rules.sh 2>/dev/null || true

# Force an absolute rtkbase_path in the environment: in the git-pull branch of
# tools/install.sh (taken here, since the "rtkbase" symlink already has a
# .git dir), _add_rtkbase_path_to_environment() is never called, so
# rtkbase_path would otherwise default to the relative 'rtkbase' (main(),
# tools/install.sh). Exporting it here makes main() pick up the absolute
# path instead, without touching the upstream script.
export rtkbase_path="$(pwd)/rtkbase"

# Defensive chmod: ensure the precompiled RTKLIB binaries for this architecture
# keep their executable bit regardless of git's tracked file mode (e.g. after a
# fresh clone/pull where the mode may have been stored as non-executable).
chmod +x tools/bin/RTKLIB-2.5.0/aarch64/str2str tools/bin/RTKLIB-2.5.0/aarch64/rtkrcv tools/bin/RTKLIB-2.5.0/aarch64/convbin tools/bin/RTKLIB-2.5.0/aarch64/rnx2rtkp 2>/dev/null || true

./tools/install.sh --all repo --rtkbase-repo main --user "${SUDO_USER:-$USER}" --start-services

# tools/install.sh's internal git operations run as root (whole script is
# sudo'd), which can leave a few .git internal files (FETCH_HEAD, ORIG_HEAD)
# root-owned even though bootstrap_repo() already chown'd everything earlier.
# Fix ownership again here, now that tools/install.sh has finished running.
if [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "${SUDO_USER}":"${SUDO_USER}" "${SCRIPT_DIR}/.git" 2>/dev/null || true
fi

# --- Firewall: allow this station's actual service ports, then enable UFW ---
# GeoMaxima: moved here (after tools/install.sh has just created
# settings.conf) rather than in tools/security_setup.sh (STAGE 2, which
# runs BEFORE settings.conf exists) - see tools/security_setup.sh's header
# comment and tools/geomaxima_configure_firewall.sh for the full "why".
chmod +x tools/geomaxima_configure_firewall.sh 2>/dev/null || true
./tools/geomaxima_configure_firewall.sh settings.conf || log "WARNING: firewall configuration step failed - UFW may still be disabled. Run tools/geomaxima_configure_firewall.sh manually once resolved."

# --- 4. Final checklist ---
echo ""
echo "============================================================================"
echo "STAGE 4/5: Finalization and Checklist"
echo "============================================================================"

WEB_PORT=$(python3 -c "import os; print(os.getenv('WEB_PORT', 80))")
WEB_URL="http://$(hostname -I | awk '{print $1}'):${WEB_PORT}"
echo "Web Access URL: $WEB_URL"

echo ""
echo "--- Installation Checklist ---"
echo "1. RTKBase Web Service Status:"
systemctl status rtkbase_web.service | grep Active

echo ""
echo "2. UFW Status:"
ufw status verbose

echo ""
echo "3. Fail2ban Status:"
fail2ban-client status sshd || echo "fail2ban not active (user may have declined during security setup)"

echo ""
echo "4. Git remote (sanity check that git pull didn't repoint this checkout to upstream):"
echo 'Git remote: ' && git -C rtkbase remote get-url origin

echo ""
echo "============================================================================"
echo "Fetching ANTEX (igs20.atx) for PPP-static antenna corrections"
echo "============================================================================"
# One-time, install-level download - NOT per-survey, NOT committed to git
# (~54MB uncompressed). Idempotent: skips if already present, so re-running
# install.sh (or an OTA update calling this same logic in perform_update.sh)
# never re-downloads an already-fetched file. Path matches
# addons/features/auto_survey/ppp_processor.py's DEFAULT_ANTEX_RELATIVE_PATH.
ANTEX_DIR="$SCRIPT_DIR/geomaxima_ppp"
ANTEX_PATH="$ANTEX_DIR/igs20.atx"
if [ -f "$ANTEX_PATH" ]; then
    echo "ANTEX file already present at $ANTEX_PATH - skipping download."
else
    mkdir -p "$ANTEX_DIR"
    if curl -fsSL "https://files.igs.org/pub/station/general/igs20.atx.gz" -o "$ANTEX_DIR/igs20.atx.gz"; then
        if gzip -d "$ANTEX_DIR/igs20.atx.gz"; then
            echo "✓ ANTEX file downloaded and decompressed to $ANTEX_PATH"
            if [[ -n "${SUDO_USER:-}" ]]; then
                chown -R "${SUDO_USER}":"${SUDO_USER}" "$ANTEX_DIR" || log "WARNING: chown of $ANTEX_DIR to $SUDO_USER failed"
            fi
        else
            echo "⚠ ANTEX download succeeded but decompression failed - PPP-static will not work until this is resolved manually" >&2
        fi
    else
        echo "⚠ ANTEX download failed (network issue?) - PPP-static will not work until this is resolved. Re-run install.sh, or manually download https://files.igs.org/pub/station/general/igs20.atx.gz to $ANTEX_PATH (decompressed)." >&2
    fi
fi

echo ""
echo "============================================================================"
echo "Installing PRIDE-PPPAR (pdp3) for optional PPP-AR ambiguity resolution"
echo "============================================================================"
# Opt-in feature (addons/features/auto_survey/pride_pppar_processor.py) -
# rnx2rtkp remains the default PPP-static backend regardless of whether this
# succeeds. Warning-only on any failure (matches this script's existing
# PREEMPT_RT/root-resize defensive-check pattern above) - a build failure on
# some future board/toolchain combination must never hard-fail the whole
# install.
#
# Idempotent: skipped entirely if ~/.PRIDE_PPPAR_BIN/pdp3 already exists and
# is executable (this is PRIDE-PPPAR's OWN install convention, not something
# this project chose - see pride_pppar_processor.py's find_pdp3()), so
# re-running install.sh never re-copies/rebuilds the vendored source, which
# is slow to build (Fortran) on a Pi 3B.
#
# Install-user/home resolution matches the SAME "${SUDO_USER:-$USER}"
# convention already used for tools/copy_unit.sh's --user argument at
# STAGE 3 above (install.sh:207) - not a new convention, and never
# hardcoded to any specific username (e.g. "peshovp").
PRIDE_PPPAR_USER="${SUDO_USER:-$USER}"
PRIDE_PPPAR_USER_HOME="$(getent passwd "$PRIDE_PPPAR_USER" | cut -d: -f6)"
PRIDE_PPPAR_USER_HOME="${PRIDE_PPPAR_USER_HOME:-/root}"
PRIDE_PPPAR_BIN="${PRIDE_PPPAR_USER_HOME}/.PRIDE_PPPAR_BIN/pdp3"

# Vendored source (addons/PRIDE-PPPAR/, committed to this repo) - no longer
# cloned from GitHub at install time. PrideLab/PRIDE-PPPAR's own install.sh
# writes build outputs into ./src (make/make install) and reads
# ./table/config_template, so it must run from a writable COPY of the
# vendored tree, not directly against this repo's checkout (which must stay
# clean/read-only from install.sh's perspective) - copied into the install
# user's home directory, same target path ($PRIDE_PPPAR_USER_HOME/PRIDE-PPPAR)
# the old clone step used, just populated by cp now instead of git clone.
# This also removes the prior network-dependency entirely (no more
# GitHub clone, no more transient "Could not resolve host" failures at
# remote sites like BaseStation - see the removed retry logic this
# replaces).
PRIDE_PPPAR_VENDORED_SRC="$SCRIPT_DIR/addons/PRIDE-PPPAR"
PRIDE_PPPAR_REPO_DIR="${PRIDE_PPPAR_USER_HOME}/PRIDE-PPPAR"

if [ -x "$PRIDE_PPPAR_BIN" ]; then
    echo "✓ PRIDE-PPPAR already installed at $PRIDE_PPPAR_BIN - skipping build."
elif [ ! -d "$PRIDE_PPPAR_VENDORED_SRC/src" ]; then
    echo "WARNING: vendored PRIDE-PPPAR source not found at $PRIDE_PPPAR_VENDORED_SRC - skipping (this is an opt-in feature)." >&2
    echo "rnx2rtkp PPP-static remains fully functional regardless." >&2
else
    echo "Copying vendored PRIDE-PPPAR source into $PRIDE_PPPAR_REPO_DIR..."
    rm -rf "$PRIDE_PPPAR_REPO_DIR"
    if sudo -u "$PRIDE_PPPAR_USER" cp -r "$PRIDE_PPPAR_VENDORED_SRC" "$PRIDE_PPPAR_REPO_DIR"; then

        # CRITICAL BUILD FIX: gfortran 14.2.0 (Debian 14.2.0-19, aarch64) has
        # a genuine internal compiler error (segfault during the "fre"
        # GIMPLE optimization pass) at -O1/-O2/-O3, confirmed reproducible
        # on multiple PRIDE-PPPAR source files (ambpenalty.f90, ambslv.f90,
        # asknewet.f90, bdeci.f90), independent of parallelism. Forcing all
        # Makefiles to -O0 fully fixes this - confirmed all 10 modules
        # (lib, spp, orbit, tedit, lsq, redig, arsig, utils, otl, mhm) build
        # cleanly, including the critical arsig (ambiguity-resolution)
        # module, with only cosmetic Fortran-2018-deleted-feature warnings
        # (legacy GOTO/DO-label syntax) remaining. MUST run before
        # install.sh's build step.
        echo "Applying -O0 workaround for gfortran aarch64 ICE (ambpenalty.f90/ambslv.f90/asknewet.f90/bdeci.f90 segfault at -O1+)..."
        find "$PRIDE_PPPAR_REPO_DIR" -name Makefile -exec sed -i 's/-O3/-O0/g; s/-O2/-O0/g; s/-O1/-O0/g' {} \;

        sudo -u "$PRIDE_PPPAR_USER" chmod +x "$PRIDE_PPPAR_REPO_DIR/install.sh" 2>/dev/null || true

        echo "Building PRIDE-PPPAR (non-interactive)..."
        # PRIDE-PPPAR's own install.sh prompts interactively (e.g. "run
        # tests?") - piping empty answers via `yes ""` answers every prompt
        # with its default, matching this project's general
        # "install.sh must never block waiting for input" requirement.
        if (cd "$PRIDE_PPPAR_REPO_DIR" && sudo -u "$PRIDE_PPPAR_USER" bash -c 'yes "" | ./install.sh'); then
            if [ -x "$PRIDE_PPPAR_BIN" ]; then
                echo "✓ PRIDE-PPPAR built successfully: $PRIDE_PPPAR_BIN"
                # No git tag is pinned upstream (PrideLab/PRIDE-PPPAR has no
                # semver-style release tags - vendored source is simply
                # whatever snapshot was committed to addons/PRIDE-PPPAR/), so
                # the actually-installed version can only be confirmed by
                # reading the vendored tree's own self-reported version
                # string, per its README.md header line (confirmed live,
                # e.g. "## PRIDE-PPPAR ver. 3.2.11 (last updated on
                # 2026-09-20)") - logged explicitly so every install/update
                # log unambiguously records which version actually got
                # installed.
                detected_version=$(grep -oE 'PRIDE-PPPAR ver\.? [0-9]+\.[0-9]+(\.[0-9]+)?' "$PRIDE_PPPAR_REPO_DIR/README.md" 2>/dev/null | head -1)
                if [ -n "$detected_version" ]; then
                    echo "PRIDE-PPPAR version installed: $detected_version"
                else
                    echo "WARNING: PRIDE-PPPAR built successfully but version string could not be detected from README.md" >&2
                fi
            else
                echo "WARNING: PRIDE-PPPAR install.sh completed but $PRIDE_PPPAR_BIN was not found afterward." >&2
                echo "PRIDE-PPPAR ambiguity resolution (opt-in) will not be available until this is resolved manually." >&2
                echo "rnx2rtkp PPP-static remains fully functional regardless." >&2
            fi
        else
            echo "WARNING: PRIDE-PPPAR build failed - continuing install (this is an opt-in feature)." >&2
            echo "rnx2rtkp PPP-static remains fully functional regardless." >&2
            echo "Investigate manually at $PRIDE_PPPAR_REPO_DIR if PRIDE-PPPAR ambiguity resolution is needed on this station." >&2
        fi
    else
        echo "WARNING: failed to copy vendored PRIDE-PPPAR source to $PRIDE_PPPAR_REPO_DIR - continuing install (this is an opt-in feature)." >&2
        echo "rnx2rtkp PPP-static remains fully functional regardless." >&2
    fi
fi

echo ""
echo "============================================================================"
echo "Ensuring /var/log/rtkbase/ exists (needed by geomaxima_watchdog.service)"
echo "============================================================================"
# Idempotent: mkdir -p is a no-op if the directory already exists. Owned by
# root, NOT $SUDO_USER - unlike ANTEX/geoid above, geomaxima_watchdog.service
# runs as User=root (addons/unit/geomaxima_watchdog.service), not as the
# installing user, so root ownership is correct here despite looking like a
# deviation from the ANTEX pattern just above. Without this directory,
# run_watchdog_check.py's logging.FileHandler('/var/log/rtkbase/watchdog.log')
# call raises FileNotFoundError on every run (confirmed live on BaseStation:
# geomaxima_watchdog.service crash-looped every minute via
# geomaxima_watchdog.timer until this directory was created manually).
mkdir -p /var/log/rtkbase
chown root:root /var/log/rtkbase || log "WARNING: chown of /var/log/rtkbase to root failed"

# --- Re-check kernel-symlink consistency at the very end ---
# GeoMaxima: tools/install.sh and security_setup.sh (both run above, in
# STAGE 2/3) install packages of their own and could themselves introduce a
# kernel package - the EARLY check a few hundred lines up would miss a
# mismatch caused by this script's own later steps. This is the check that
# actually protects the upcoming reboot; halts (does not just warn) with a
# "do NOT reboot" message if the symlinks disagree right now.
geomaxima_check_kernel_symlink_consistency end

echo ""
echo "============================================================================"
echo "STAGE 5/5: INSTALLATION COMPLETE! Please review the status above."
echo "============================================================================"
echo "Remember to check the logs and test connectivity."
