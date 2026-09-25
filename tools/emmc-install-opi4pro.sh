#!/usr/bin/env bash
# =============================================================================
#  tools/emmc-install-opi4pro.sh
#  Armbian: copies the system from an SD card to eMMC on an Orange Pi 4 Pro+
#  (Allwinner A733/sun60iw2).
#
#  Works around two armbian-install bugs on this board:
#    1) misdetects SD/eMMC (tries to wipe the SD card the system is
#       actually booted from)
#    2) creates the root partition at 16 MiB, which the vendor U-Boot's
#       boot_package.fex write (seek=16400K) overlaps - see
#       tools/install.sh's/install.sh's own bootloader-overlap check for
#       the live-confirmed consequences of this.
#
#  GeoMaxima: refactored into a sourceable function,
#  geomaxima_emmc_migrate(), plus a thin CLI wrapper below, so install.sh
#  can call it directly and non-interactively as part of the unattended
#  curl|bash one-liner (Plan B) instead of only via a separate manual
#  invocation. The CLI wrapper preserves the original standalone usage.
#
#  Usage (standalone):  sudo ./tools/emmc-install-opi4pro.sh [-y|--yes] [--no-hold]
#    -y, --yes    skip the interactive confirmation (used automatically
#                 when called as geomaxima_emmc_migrate from install.sh)
#    --no-hold    don't apt-mark hold the kernel/dtb/u-boot/bsp/firmware
#                 packages after copying (holding is now supplementary to
#                 the apt preferences pin written into the eMMC target
#                 below - see tools/armbian_kernel_pin.sh)
#
#  Usage (sourced):
#    source tools/emmc-install-opi4pro.sh
#    geomaxima_emmc_migrate [assume_yes=1] [hold=1]
#    (both arguments are 0/1, default 1/1 - i.e. non-interactive, holding
#    enabled - matching how install.sh's Plan B flow calls this)
# =============================================================================

GM_EMMC_PART_START=65536  # sectors = 32 MiB (matches the official image)
GM_EMMC_PLATFORM_SCRIPT="/usr/lib/u-boot/platform_install.sh"
GM_EMMC_MNT="/mnt/emmc-target"
GM_EMMC_LOG="/var/log/emmc-install-opi4pro.log"

geomaxima_emmc_log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
geomaxima_emmc_warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
geomaxima_emmc_die()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; return 1; }

# Migration marker written to the eMMC target (persists across reboots,
# read back by install.sh's Plan B flow so re-running the one-liner from
# SD never re-migrates an already-prepared eMMC unless explicitly forced).
GM_EMMC_MARKER_PATH="etc/geomaxima/migrated-from-sd"

geomaxima_emmc_migrate() {
    local assume_yes="${1:-1}"
    local do_hold="${2:-1}"

    set -o pipefail
    exec > >(tee -a "$GM_EMMC_LOG") 2>&1
    geomaxima_emmc_log "Starting eMMC migration: $(date)"

    # --- 0. Required tools ---------------------------------------------------
    local c
    for c in parted rsync wipefs e2fsck mkfs.ext4 partprobe blkid; do
        command -v "$c" >/dev/null || {
            geomaxima_emmc_warn "Missing $c - installing..."
            apt-get update -qq
            apt-get install -y rsync parted e2fsprogs util-linux
            break
        }
    done

    # --- 1. Discover the devices (by TYPE, not by name) -----------------------
    local root_part root_disk root_name
    root_part=$(findmnt -no SOURCE /)
    root_disk=/dev/$(lsblk -no PKNAME "$root_part")
    root_name=$(basename "$root_disk")
    [[ "$(cat "/sys/block/$root_name/device/type" 2>/dev/null)" == "SD" ]] \
        || { geomaxima_emmc_die "Root ($root_part) is NOT on an SD card. This migration only runs when booted from SD."; return 1; }

    local emmc="" b n
    for b in /sys/block/mmcblk*; do
        n=$(basename "$b")
        [[ $n =~ ^mmcblk[0-9]+$ ]] || continue
        if [[ "$(cat "$b/device/type" 2>/dev/null)" == "MMC" ]]; then
            [[ -z "$emmc" ]] || { geomaxima_emmc_die "Multiple eMMC devices found - aborting."; return 1; }
            emmc=/dev/$n
        fi
    done
    [[ -n "$emmc" ]] || { geomaxima_emmc_die "No eMMC device found."; return 1; }
    [[ "$emmc" != "$root_disk" ]] || { geomaxima_emmc_die "eMMC matches the root disk - aborting."; return 1; }
    local emmc_name emmc_part
    emmc_name=$(basename "$emmc")
    emmc_part="${emmc}p1"

    if lsblk -no MOUNTPOINTS "$emmc" | grep -q .; then
        geomaxima_emmc_die "A partition of $emmc is mounted. Unmount it (or reboot) and try again."
        return 1
    fi

    # --- Re-migration guard: eMMC already prepared? ---------------------------
    # GeoMaxima: mount read-only just far enough to check for the marker
    # before doing anything destructive. If already migrated and the
    # caller didn't force it, stop here rather than re-copying (which would
    # also re-run the bootloader write - unnecessary and slower).
    if [[ "${GM_EMMC_FORCE:-0}" != "1" ]]; then
        local premount="/mnt/emmc-check-$$"
        mkdir -p "$premount"
        if mount -o ro "$emmc_part" "$premount" 2>/dev/null; then
            local already_migrated=0
            [[ -f "$premount/$GM_EMMC_MARKER_PATH" ]] && already_migrated=1
            umount "$premount" 2>/dev/null || true
            rmdir "$premount" 2>/dev/null || true
            if [[ "$already_migrated" == "1" ]]; then
                geomaxima_emmc_log "eMMC already prepared (marker found at /$GM_EMMC_MARKER_PATH) - not re-migrating."
                geomaxima_emmc_log "Remove the SD card and power on to boot from eMMC."
                geomaxima_emmc_log "(Set GM_EMMC_FORCE=1 to force re-migration anyway.)"
                return 0
            fi
        else
            rmdir "$premount" 2>/dev/null || true
        fi
    fi

    geomaxima_emmc_log "Root (SD): $root_part   ->   target (eMMC): $emmc"

    # --- 2. Bootloader location sanity check -----------------------------------
    [[ -f "$GM_EMMC_PLATFORM_SCRIPT" ]] || { geomaxima_emmc_die "Missing $GM_EMMC_PLATFORM_SCRIPT"; return 1; }
    local uboot_dir
    uboot_dir=$(ls -d /usr/lib/linux-u-boot-* 2>/dev/null | head -1 || true)
    [[ -n "$uboot_dir" ]] || { geomaxima_emmc_die "No /usr/lib/linux-u-boot-* found."; return 1; }
    local f
    for f in boot0_sdcard.fex boot_package.fex; do
        [[ -f "$uboot_dir/$f" ]] || { geomaxima_emmc_die "Missing $uboot_dir/$f"; return 1; }
    done
    bash -c "source '$GM_EMMC_PLATFORM_SCRIPT'; declare -F write_uboot_platform" >/dev/null \
        || { geomaxima_emmc_die "write_uboot_platform is not defined in $GM_EMMC_PLATFORM_SCRIPT."; return 1; }

    local bp_seek_k bp_size_k bp_end_k part_start_k
    bp_seek_k=$(grep -oP 'boot_package\.fex.*bs=1k seek=\K[0-9]+' "$GM_EMMC_PLATFORM_SCRIPT" | head -1 || true)
    [[ -n "$bp_seek_k" ]] || { bp_seek_k=16400; geomaxima_emmc_warn "Could not find boot_package seek offset, assuming 16400K."; }
    bp_size_k=$(( ( $(stat -c%s "$uboot_dir/boot_package.fex") + 1023 ) / 1024 ))
    bp_end_k=$(( bp_seek_k + bp_size_k ))
    part_start_k=$(( GM_EMMC_PART_START / 2 ))
    geomaxima_emmc_log "boot_package: ${bp_seek_k}K - ${bp_end_k}K; target partition starts at ${part_start_k}K"
    (( bp_end_k < part_start_k )) || { geomaxima_emmc_die "Bootloader would overlap the partition! Increase GM_EMMC_PART_START."; return 1; }

    local used_k emmc_k
    used_k=$(df -k --output=used / | tail -1)
    emmc_k=$(( $(cat "/sys/block/$emmc_name/size") / 2 ))
    (( used_k + 1048576 < emmc_k - part_start_k )) || { geomaxima_emmc_die "eMMC is too small for this system."; return 1; }

    # --- 3. Confirmation --------------------------------------------------------
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$root_disk" "$emmc"
    if [[ "$assume_yes" != "1" ]]; then
        echo
        geomaxima_emmc_warn "ALL DATA ON $emmc WILL BE ERASED."
        local ans
        read -rp "Type YES to continue: " ans
        [[ "$ans" == "YES" ]] || { geomaxima_emmc_die "Aborted."; return 1; }
    fi

    # --- 4. Hold packages (before copying, so the hold state itself is
    # carried onto the eMMC copy) -------------------------------------------
    if [[ "$do_hold" == "1" ]]; then
        local pkgs
        pkgs=$(dpkg -l | awk '/^ii/ && /linux-(image|dtb|u-boot)|armbian-bsp|armbian-firmware/ {print $2}')
        if [[ -n "$pkgs" ]]; then
            # shellcheck disable=SC2086
            apt-mark hold $pkgs
        fi
    fi

    # --- 5. Wipe and partition ---------------------------------------------
    geomaxima_emmc_log "Wiping $emmc..."
    wipefs -a "${emmc}"p* 2>/dev/null || true
    wipefs -a "$emmc"
    dd if=/dev/zero of="$emmc" bs=1M count=64 status=none conv=fsync
    partprobe "$emmc" || true

    geomaxima_emmc_log "Creating partition at sector $GM_EMMC_PART_START..."
    parted -s "$emmc" mklabel msdos mkpart primary ext4 "${GM_EMMC_PART_START}s" 100%
    partprobe "$emmc"; udevadm settle; sleep 1
    [[ -b "$emmc_part" ]] || { geomaxima_emmc_die "$emmc_part did not appear."; return 1; }
    local real_start
    real_start=$(cat "/sys/block/$emmc_name/${emmc_name}p1/start")
    [[ "$real_start" == "$GM_EMMC_PART_START" ]] || { geomaxima_emmc_die "Partition starts at $real_start, expected $GM_EMMC_PART_START."; return 1; }

    mkfs.ext4 -F -q -L armbi_emmc "$emmc_part"

    # --- 6. Bootloader (before copying - to verify it doesn't touch the FS) ---
    geomaxima_emmc_log "Writing bootloader from $uboot_dir..."
    bash -c "source '$GM_EMMC_PLATFORM_SCRIPT'; write_uboot_platform '$uboot_dir' '$emmc'" \
        || { geomaxima_emmc_die "Bootloader write failed."; return 1; }
    sync
    e2fsck -fn "$emmc_part" >/dev/null || { geomaxima_emmc_die "Filesystem is corrupted after the bootloader write!"; return 1; }
    geomaxima_emmc_log "Filesystem is clean after the bootloader write."

    # --- 7. Mount and pin the Armbian kernel BEFORE rsync ----------------------
    # GeoMaxima: the pin must exist inside the eMMC copy itself, written
    # before rsync so it survives as part of the copy - writing it only to
    # the SD source (or only to the running system) would never reach the
    # eMMC target. tools/armbian_kernel_pin.sh's function takes an optional
    # target-root argument for exactly this ("apply under an alternate
    # root") case.
    mkdir -p "$GM_EMMC_MNT"
    mount "$emmc_part" "$GM_EMMC_MNT"
    trap 'mountpoint -q "$GM_EMMC_MNT" && umount "$GM_EMMC_MNT" || true' RETURN

    local pin_script_dir
    pin_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$pin_script_dir/armbian_kernel_pin.sh" ]]; then
        # shellcheck source=tools/armbian_kernel_pin.sh
        source "$pin_script_dir/armbian_kernel_pin.sh"
        geomaxima_apply_armbian_kernel_pin "$GM_EMMC_MNT"
    else
        geomaxima_emmc_warn "tools/armbian_kernel_pin.sh not found next to this script - the eMMC copy will NOT have the kernel pin until install.sh/perform_update.sh next applies it."
    fi

    # --- 8. Copy --------------------------------------------------------------
    geomaxima_emmc_log "Copying the system (rsync)..."
    rsync -aAXHx --info=progress2 / "$GM_EMMC_MNT"/

    # --- 9. UUID ----------------------------------------------------------------
    local old_uuid new_uuid
    old_uuid=$(blkid -s UUID -o value "$root_part")
    new_uuid=$(blkid -s UUID -o value "$emmc_part")
    [[ "$old_uuid" != "$new_uuid" ]] || { geomaxima_emmc_die "UUIDs match - something is wrong."; return 1; }
    geomaxima_emmc_log "UUID: $old_uuid -> $new_uuid"
    sed -i "s/$old_uuid/$new_uuid/g" "$GM_EMMC_MNT/boot/armbianEnv.txt" "$GM_EMMC_MNT/etc/fstab"
    grep -q "rootdev=UUID=$new_uuid" "$GM_EMMC_MNT/boot/armbianEnv.txt" || { geomaxima_emmc_die "rootdev in armbianEnv.txt was not updated!"; return 1; }
    grep -q "^UUID=$new_uuid" "$GM_EMMC_MNT/etc/fstab" || { geomaxima_emmc_die "/ in fstab was not updated!"; return 1; }

    # --- 10. Migration marker (written LAST, only once everything else
    # above has succeeded - its presence is exactly what the re-migration
    # guard at the top of this function checks for) ---------------------------
    mkdir -p "$GM_EMMC_MNT/etc/geomaxima"
    {
        echo "migrated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "migrated_from=$root_part"
        echo "migrated_to=$emmc_part"
    } > "$GM_EMMC_MNT/$GM_EMMC_MARKER_PATH"

    sync
    umount "$GM_EMMC_MNT"
    trap - RETURN

    # --- 11. Final check ---------------------------------------------------
    e2fsck -fn "$emmc_part" || { geomaxima_emmc_die "Final filesystem check failed!"; return 1; }
    local files
    files=$(dumpe2fs -h "$emmc_part" 2>/dev/null | awk -F: '/Inode count/{t=$2} /Free inodes/{f=$2} END{print t-f}')
    geomaxima_emmc_log "Files on eMMC: $files"

    echo
    geomaxima_emmc_log "DONE. eMMC at $emmc_part is ready."
    geomaxima_emmc_log "Log: $GM_EMMC_LOG"
    return 0
}

# --- Optional: erase only the SD card's bootloader area, so the A733 BROM
# falls through to eMMC without physically removing the SD card. UNVERIFIED
# ON HARDWARE - kept behind GM_WIPE_SD_BOOT=yes (checked by the caller,
# install.sh) until confirmed the BROM actually falls through when SD
# boot0 is missing; the safe default path is to poweroff and ask the user
# to remove the SD card instead.
#
# Reads the SD's OWN root partition start from sysfs rather than assuming
# 32 MiB (that constant is this function's TARGET eMMC layout, not
# necessarily the SD's existing layout) - zeros only from 8K (below
# boot0_sdcard.fex's known 8K offset - see emmc-install-opi4pro.sh's own
# header comment) up to, but not including, wherever the SD's root
# partition actually starts, so the filesystem itself is never touched.
geomaxima_wipe_sd_bootloader() {
    local sd_part sd_disk sd_name
    sd_part=$(findmnt -no SOURCE / 2>/dev/null || true)
    [[ -n "$sd_part" ]] || { geomaxima_emmc_die "Could not determine the SD root partition."; return 1; }
    sd_disk=/dev/$(lsblk -no PKNAME "$sd_part" 2>/dev/null || true)
    sd_name=$(basename "$sd_disk")
    [[ "$(cat "/sys/block/$sd_name/device/type" 2>/dev/null)" == "SD" ]] \
        || { geomaxima_emmc_die "$sd_disk does not report as an SD card - refusing to wipe it."; return 1; }

    local sd_part_name sd_part_start_sectors sd_part_start_k
    sd_part_name=$(basename "$sd_part")
    sd_part_start_sectors=$(cat "/sys/block/$sd_name/$sd_part_name/start" 2>/dev/null || echo 0)
    sd_part_start_k=$(( sd_part_start_sectors / 2 ))
    if (( sd_part_start_k <= 8 )); then
        geomaxima_emmc_die "SD root partition starts at ${sd_part_start_k}K, at or below the 8K boot0 offset - refusing to wipe (would touch the filesystem)."
        return 1
    fi
    local wipe_count_k=$(( sd_part_start_k - 8 ))

    geomaxima_emmc_warn "Erasing SD bootloader area on $sd_disk: 8K-${sd_part_start_k}K (${wipe_count_k}K), leaving the filesystem (starts at ${sd_part_start_k}K) untouched."
    dd if=/dev/zero of="$sd_disk" bs=1024 seek=8 count="$wipe_count_k" conv=fsync status=none
    sync
    geomaxima_emmc_log "SD bootloader area erased. The board should now fall through to eMMC on next boot (UNVERIFIED on this hardware - confirm before relying on this in production)."
}

# --- CLI wrapper (only runs when this script is executed directly, not
# when sourced - preserves the original standalone usage) -------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    GM_CLI_ASSUME_YES=0
    GM_CLI_HOLD=1
    for a in "$@"; do
        case "$a" in
            -y|--yes)  GM_CLI_ASSUME_YES=1 ;;
            --no-hold) GM_CLI_HOLD=0 ;;
            -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
            *) echo "Unknown option: $a" >&2; exit 1 ;;
        esac
    done

    [[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }

    set -uo pipefail
    geomaxima_emmc_migrate "$GM_CLI_ASSUME_YES" "$GM_CLI_HOLD"
    exit $?
fi
