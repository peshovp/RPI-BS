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
#       boot_package.fex write (seek=16400K) overlaps - see install.sh's
#       own bootloader-overlap check for the live-confirmed consequences.
#
#  GeoMaxima: refactored into a sourceable function,
#  geomaxima_emmc_migrate(), plus a thin CLI wrapper below, so install.sh
#  can call it directly and non-interactively as part of the unattended
#  curl|bash one-liner (Plan B) instead of only via a separate manual
#  invocation. The CLI wrapper preserves the original standalone usage.
#
#  IMPORTANT: the real work happens in _gm_emmc_migrate_impl(), which does
#  NOT use `set -e` - bash disables `errexit` inside a function whose call
#  is itself the condition of an `if`/`while`/`&&`/`||` (exactly how
#  install.sh calls geomaxima_emmc_migrate) - relying on `set -e` here
#  would silently skip error handling on every failure. Every destructive
#  or state-changing step below therefore has an EXPLICIT `|| return 1`
#  (or equivalent), checked individually. Do not add a step without the
#  same explicit check.
#
#  IMPORTANT: this function does NOT use `trap ... RETURN` for cleanup.
#  Confirmed live (bash 5.2) that a RETURN trap set inside a function fires
#  not only when the function itself returns, but ALSO every time a
#  `source`/`.` command completes inside that function:
#    f(){ trap 'echo FIRED' RETURN; source ./x.sh; echo after; }; f
#  prints FIRED before "after". A RETURN trap set right after `mount`
#  (this function's earlier design) would have unmounted the eMMC target
#  the moment `source tools/armbian_kernel_pin.sh` completed - BEFORE the
#  pin was actually written and before rsync ran - silently redirecting
#  every subsequent write (the pin, then rsync's entire copy) onto the
#  SD's own root filesystem instead (same filesystem, `-x` does not
#  exclude an unmounted-but-still-present directory), filling the SD card.
#  Fixed by: (1) sourcing armbian_kernel_pin.sh at the very top, before any
#  mount; (2) an explicit _gm_emmc_cleanup() call at every failure/return
#  point after the mount succeeds, never a trap; (3) a defense-in-depth
#  `findmnt` check immediately before rsync and before every write into
#  $GM_EMMC_MNT, so an unexpectedly-unmounted target is caught rather than
#  silently written through to whatever is now at that path.
#
#  Return code contract for geomaxima_emmc_migrate() (callers must check
#  this exactly, not just "truthy/falsy" - see install.sh's `rc=$?` usage):
#    0  = migration completed successfully, eMMC is ready
#    2  = eMMC was ALREADY prepared (migration marker found) - nothing was
#         written or changed; this is a safe "already done" outcome
#    1  = FAILED - do not poweroff assuming success, do not wipe the SD
#         bootloader, do not write phase-2 handoff files. Caller must
#         surface the error and the log path, then exit non-zero.
#  (`return 1` is used consistently for every failure path below purely
#  for uniformity; the distinguishing case callers must handle specially
#  is `2`, not any particular non-zero/non-two value.)
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
#
#  On return 0, the function also sets (not `local`, so still readable by
#  the caller after the call): GM_EMMC_RESULT_DISK (e.g. "/dev/mmcblk0")
#  and GM_EMMC_RESULT_PART (e.g. "/dev/mmcblk0p1") - the eMMC disk/partition
#  actually used, so the caller never needs to re-scan /sys/block itself.
# =============================================================================

GM_EMMC_PART_START=65536  # sectors = 32 MiB (matches the official image)
GM_EMMC_PLATFORM_SCRIPT="${GM_EMMC_PLATFORM_SCRIPT:-/usr/lib/u-boot/platform_install.sh}"
GM_EMMC_MNT="/mnt/emmc-target"
GM_EMMC_LOG="/var/log/emmc-install-opi4pro.log"

# --- Test seams -------------------------------------------------------------
# GeoMaxima: these all default to the real path/value used on an actual
# board - behavior there is completely unchanged. They exist so a test
# harness (e.g. a Linux sandbox with loop devices, a fake sysfs tree, and a
# fake platform_install.sh) can exercise this function end-to-end without
# touching real hardware, WITHOUT adding any "if test mode" branches to the
# logic itself - every code path below reads through one of these
# variables instead of a hardcoded real path.
#   GM_SYSFS            - root of the sysfs tree (real: /sys)
#   GM_TEST_ROOT_PART    - the "source root" partition device (real: read
#                          from `findmnt -no SOURCE /`)
#   GM_ROOT_SRC          - the rsync source directory (real: /)
#   GM_UBOOT_DIR         - the u-boot install directory (real: discovered
#                          via `ls -d /usr/lib/linux-u-boot-*`)
# GM_EMMC_PLATFORM_SCRIPT (above) is also overridable the same way, so a
# test can supply a fake platform_install.sh with the same dd/seek offsets
# and a fake boot_package.fex/boot0_sdcard.fex of realistic sizes.
GM_SYSFS="${GM_SYSFS:-/sys}"
GM_ROOT_SRC="${GM_ROOT_SRC:-/}"

geomaxima_emmc_log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
geomaxima_emmc_warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
geomaxima_emmc_die()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; }

# Migration marker written to the eMMC target (persists across reboots,
# read back by install.sh's Plan B flow so re-running the one-liner from
# SD never re-migrates an already-prepared eMMC unless explicitly forced).
GM_EMMC_MARKER_PATH="etc/geomaxima/migrated-from-sd"

# _gm_emmc_cleanup(): unmount $GM_EMMC_MNT if it's mounted. Called
# EXPLICITLY at every failure/return point in _gm_emmc_migrate_impl()
# after the mount succeeds - NOT via a trap. See this file's header
# comment for exactly why a RETURN trap is unsafe here.
_gm_emmc_cleanup() {
    mountpoint -q "$GM_EMMC_MNT" 2>/dev/null && umount "$GM_EMMC_MNT" 2>/dev/null
    return 0
}

# _gm_emmc_assert_mounted(): defense-in-depth check, called immediately
# before rsync and before every write into $GM_EMMC_MNT - verifies the
# mountpoint is STILL backed by the eMMC partition we mounted, not
# (silently) unmounted or replaced by something else. Returns non-zero
# (and logs) if not.
_gm_emmc_assert_mounted() {
    local expected_part="$1"
    local actual_source
    actual_source="$(findmnt -no SOURCE "$GM_EMMC_MNT" 2>/dev/null || true)"
    if [[ "$actual_source" != "$expected_part" ]]; then
        geomaxima_emmc_die "$GM_EMMC_MNT is not mounted from $expected_part (found: '${actual_source:-<nothing mounted>}') - refusing to write here."
        return 1
    fi
    return 0
}

# _gm_emmc_migrate_impl(): the actual implementation. Ordinary `return`
# statements throughout - no fd save/restore juggling needed here, that is
# handled once by the public geomaxima_emmc_migrate() wrapper below, which
# calls this and restores stdout/stderr regardless of the result.
_gm_emmc_migrate_impl() {
    local assume_yes="${1:-1}"
    local do_hold="${2:-1}"

    geomaxima_emmc_log "Starting eMMC migration: $(date)"

    # GeoMaxima: source the kernel-pin helper HERE, at the very top, before
    # ANY mount happens - see this file's header comment for why a
    # `source` running AFTER a mount was the root cause of a serious bug.
    # Sourcing this early has no downside: geomaxima_apply_armbian_kernel_pin
    # is only CALLED later (step 7, once $GM_EMMC_MNT is mounted), this
    # just makes the function available.
    local pin_script_dir
    pin_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$pin_script_dir/armbian_kernel_pin.sh" ]]; then
        # shellcheck source=tools/armbian_kernel_pin.sh
        source "$pin_script_dir/armbian_kernel_pin.sh"
    else
        geomaxima_emmc_die "tools/armbian_kernel_pin.sh not found next to this script - refusing to continue without the kernel pin (its absence is exactly the confirmed-live boot-breaking bug this migration exists to avoid)."
        return 1
    fi

    # --- 0. Required tools ---------------------------------------------------
    local c
    for c in parted rsync wipefs e2fsck mkfs.ext4 partprobe blkid; do
        if ! command -v "$c" >/dev/null; then
            geomaxima_emmc_warn "Missing $c - installing..."
            apt-get update -qq || { geomaxima_emmc_die "apt-get update failed."; return 1; }
            apt-get install -y rsync parted e2fsprogs util-linux \
                || { geomaxima_emmc_die "apt-get install failed."; return 1; }
            break
        fi
    done

    # --- 1. Discover the devices (by TYPE, not by name) -----------------------
    # GeoMaxima: root_part defaults to the real `findmnt -no SOURCE /`, but
    # is overridable via GM_TEST_ROOT_PART for a test harness that fakes
    # up a whole "source root" (e.g. a loop device with a tmpfs-backed
    # fake root) without this function needing to know it's under test.
    local root_part root_disk root_name
    if [[ -n "${GM_TEST_ROOT_PART:-}" ]]; then
        root_part="$GM_TEST_ROOT_PART"
    else
        root_part=$(findmnt -no SOURCE /) || { geomaxima_emmc_die "findmnt failed to determine the root device."; return 1; }
    fi
    root_disk=/dev/$(lsblk -no PKNAME "$root_part") || { geomaxima_emmc_die "lsblk failed to determine the root disk."; return 1; }
    root_name=$(basename "$root_disk")
    [[ "$(cat "$GM_SYSFS/block/$root_name/device/type" 2>/dev/null)" == "SD" ]] \
        || { geomaxima_emmc_die "Root ($root_part) is NOT on an SD card. This migration only runs when booted from SD."; return 1; }

    local emmc="" b n
    for b in "$GM_SYSFS"/block/mmcblk*; do
        n=$(basename "$b")
        [[ $n =~ ^mmcblk[0-9]+$ ]] || continue
        if [[ "$(cat "$b/device/type" 2>/dev/null)" == "MMC" ]]; then
            if [[ -n "$emmc" ]]; then
                geomaxima_emmc_die "Multiple eMMC devices found - aborting."
                return 1
            fi
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
    # caller didn't force it, return 2 (a distinct, explicitly-documented
    # "already done" code - see the contract in this file's header) rather
    # than re-copying (which would also re-run the bootloader write -
    # unnecessary and slower).
    if [[ "${GM_EMMC_FORCE:-0}" != "1" ]]; then
        local premount="/mnt/emmc-check-$$"
        mkdir -p "$premount" || { geomaxima_emmc_die "Could not create $premount."; return 1; }
        if mount -o ro "$emmc_part" "$premount" 2>/dev/null; then
            local already_migrated=0
            [[ -f "$premount/$GM_EMMC_MARKER_PATH" ]] && already_migrated=1
            umount "$premount" 2>/dev/null || true
            rmdir "$premount" 2>/dev/null || true
            if [[ "$already_migrated" == "1" ]]; then
                geomaxima_emmc_log "eMMC already prepared (marker found at /$GM_EMMC_MARKER_PATH) - not re-migrating."
                geomaxima_emmc_log "Remove the SD card and power on to boot from eMMC."
                geomaxima_emmc_log "(Set GM_EMMC_FORCE=1 to force re-migration anyway.)"
                return 2
            fi
        else
            rmdir "$premount" 2>/dev/null || true
        fi
    fi

    geomaxima_emmc_log "Root (SD): $root_part   ->   target (eMMC): $emmc"

    # --- 2. Bootloader location sanity check -----------------------------------
    [[ -f "$GM_EMMC_PLATFORM_SCRIPT" ]] || { geomaxima_emmc_die "Missing $GM_EMMC_PLATFORM_SCRIPT"; return 1; }
    # GeoMaxima: GM_UBOOT_DIR overridable for a test harness to point at a
    # fake u-boot directory with realistic .fex file sizes, without this
    # function needing an "if test mode" branch - real behavior (discover
    # via /usr/lib/linux-u-boot-*) is unchanged when unset.
    local uboot_dir
    if [[ -n "${GM_UBOOT_DIR:-}" ]]; then
        uboot_dir="$GM_UBOOT_DIR"
    else
        uboot_dir=$(ls -d /usr/lib/linux-u-boot-* 2>/dev/null | head -1 || true)
    fi
    [[ -n "$uboot_dir" ]] || { geomaxima_emmc_die "No /usr/lib/linux-u-boot-* found (set GM_UBOOT_DIR to override)."; return 1; }
    local f
    for f in boot0_sdcard.fex boot_package.fex; do
        [[ -f "$uboot_dir/$f" ]] || { geomaxima_emmc_die "Missing $uboot_dir/$f"; return 1; }
    done
    bash -c "source '$GM_EMMC_PLATFORM_SCRIPT'; declare -F write_uboot_platform" >/dev/null \
        || { geomaxima_emmc_die "write_uboot_platform is not defined in $GM_EMMC_PLATFORM_SCRIPT."; return 1; }

    local bp_seek_k bp_size_bytes bp_size_k bp_end_k part_start_k
    bp_seek_k=$(grep -oP 'boot_package\.fex.*bs=1k seek=\K[0-9]+' "$GM_EMMC_PLATFORM_SCRIPT" | head -1 || true)
    [[ -n "$bp_seek_k" ]] || { bp_seek_k=16400; geomaxima_emmc_warn "Could not find boot_package seek offset, assuming 16400K."; }
    # GeoMaxima: `stat` is captured into a plain variable FIRST and checked
    # on its own - `bp_size_k=$(( ($(stat ...) + 1023) / 1024 )) || ...`
    # would NOT catch a failing `stat`: a command substitution that fails
    # inside arithmetic expansion produces an empty/invalid expression,
    # which is a bash ARITHMETIC SYNTAX ERROR, not a normal non-zero exit
    # status the `||` could ever see.
    bp_size_bytes="$(stat -c%s "$uboot_dir/boot_package.fex")" || { geomaxima_emmc_die "stat on $uboot_dir/boot_package.fex failed."; return 1; }
    bp_size_k=$(( (bp_size_bytes + 1023) / 1024 ))
    bp_end_k=$(( bp_seek_k + bp_size_k ))
    part_start_k=$(( GM_EMMC_PART_START / 2 ))
    geomaxima_emmc_log "boot_package: ${bp_seek_k}K - ${bp_end_k}K; target partition starts at ${part_start_k}K"
    if (( bp_end_k >= part_start_k )); then
        geomaxima_emmc_die "Bootloader would overlap the partition! Increase GM_EMMC_PART_START."
        return 1
    fi

    local used_k emmc_size_sectors emmc_k
    used_k=$(df -k --output=used "$GM_ROOT_SRC" | tail -1) || { geomaxima_emmc_die "df failed."; return 1; }
    emmc_size_sectors="$(cat "$GM_SYSFS/block/$emmc_name/size")" || { geomaxima_emmc_die "Could not read eMMC size from sysfs."; return 1; }
    emmc_k=$(( emmc_size_sectors / 2 ))
    if (( used_k + 1048576 >= emmc_k - part_start_k )); then
        geomaxima_emmc_die "eMMC is too small for this system."
        return 1
    fi

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
    # carried onto the eMMC copy). Non-fatal on failure - apt-mark hold
    # failing is not itself dangerous, the pin (step 7) is the real
    # protection; still logged loudly so it's never silently missed.
    if [[ "$do_hold" == "1" ]]; then
        local pkgs
        pkgs=$(dpkg -l | awk '/^ii/ && /linux-(image|dtb|u-boot)|armbian-bsp|armbian-firmware/ {print $2}')
        if [[ -n "$pkgs" ]]; then
            # shellcheck disable=SC2086
            apt-mark hold $pkgs || geomaxima_emmc_warn "apt-mark hold failed for one or more packages - continuing (the apt pin in step 7 is the primary protection)."
        fi
    fi

    # --- 5. Wipe and partition (destructive - every step checked) -------------
    geomaxima_emmc_log "Wiping $emmc..."
    wipefs -a "${emmc}"p* 2>/dev/null || true
    wipefs -a "$emmc" || { geomaxima_emmc_die "wipefs on $emmc failed."; return 1; }
    dd if=/dev/zero of="$emmc" bs=1M count=64 status=none conv=fsync || { geomaxima_emmc_die "dd zero-wipe of $emmc failed."; return 1; }
    partprobe "$emmc" || true

    geomaxima_emmc_log "Creating partition at sector $GM_EMMC_PART_START..."
    parted -s "$emmc" mklabel msdos mkpart primary ext4 "${GM_EMMC_PART_START}s" 100% \
        || { geomaxima_emmc_die "parted failed to create the partition on $emmc."; return 1; }
    partprobe "$emmc" || true
    udevadm settle || true
    sleep 1
    [[ -b "$emmc_part" ]] || { geomaxima_emmc_die "$emmc_part did not appear."; return 1; }
    local real_start
    real_start=$(cat "$GM_SYSFS/block/$emmc_name/${emmc_name}p1/start") || { geomaxima_emmc_die "Could not read the new partition's start offset."; return 1; }
    [[ "$real_start" == "$GM_EMMC_PART_START" ]] || { geomaxima_emmc_die "Partition starts at $real_start, expected $GM_EMMC_PART_START."; return 1; }

    mkfs.ext4 -F -q -L armbi_emmc "$emmc_part" || { geomaxima_emmc_die "mkfs.ext4 on $emmc_part failed."; return 1; }

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
    # root") case. NO trap is used for cleanup from here on - every failure
    # path below calls _gm_emmc_cleanup() explicitly (see header comment).
    mkdir -p "$GM_EMMC_MNT" || { geomaxima_emmc_die "Could not create $GM_EMMC_MNT."; return 1; }
    mount "$emmc_part" "$GM_EMMC_MNT" || { geomaxima_emmc_die "Could not mount $emmc_part at $GM_EMMC_MNT."; return 1; }

    _gm_emmc_assert_mounted "$emmc_part" || { _gm_emmc_cleanup; return 1; }
    geomaxima_apply_armbian_kernel_pin "$GM_EMMC_MNT" \
        || { geomaxima_emmc_die "Failed to write the Armbian kernel pin into the eMMC target."; _gm_emmc_cleanup; return 1; }

    # --- 8. Copy --------------------------------------------------------------
    geomaxima_emmc_log "Copying the system (rsync)..."
    # Defense in depth immediately before the actual copy - re-verify the
    # target is still exactly the eMMC partition we mounted above.
    _gm_emmc_assert_mounted "$emmc_part" || { _gm_emmc_cleanup; return 1; }
    rsync -aAXHx --info=progress2 "$GM_ROOT_SRC" "$GM_EMMC_MNT"/ || { geomaxima_emmc_die "rsync failed."; _gm_emmc_cleanup; return 1; }

    # --- 9. UUID ----------------------------------------------------------------
    _gm_emmc_assert_mounted "$emmc_part" || { _gm_emmc_cleanup; return 1; }
    local old_uuid new_uuid
    old_uuid=$(blkid -s UUID -o value "$root_part") || { geomaxima_emmc_die "blkid on $root_part failed."; _gm_emmc_cleanup; return 1; }
    new_uuid=$(blkid -s UUID -o value "$emmc_part") || { geomaxima_emmc_die "blkid on $emmc_part failed."; _gm_emmc_cleanup; return 1; }
    [[ "$old_uuid" != "$new_uuid" ]] || { geomaxima_emmc_die "UUIDs match - something is wrong."; _gm_emmc_cleanup; return 1; }
    geomaxima_emmc_log "UUID: $old_uuid -> $new_uuid"
    sed -i "s/$old_uuid/$new_uuid/g" "$GM_EMMC_MNT/boot/armbianEnv.txt" "$GM_EMMC_MNT/etc/fstab" \
        || { geomaxima_emmc_die "sed UUID substitution failed."; _gm_emmc_cleanup; return 1; }
    grep -q "rootdev=UUID=$new_uuid" "$GM_EMMC_MNT/boot/armbianEnv.txt" || { geomaxima_emmc_die "rootdev in armbianEnv.txt was not updated!"; _gm_emmc_cleanup; return 1; }
    grep -q "^UUID=$new_uuid" "$GM_EMMC_MNT/etc/fstab" || { geomaxima_emmc_die "/ in fstab was not updated!"; _gm_emmc_cleanup; return 1; }

    # --- 10. Migration marker (written LAST, only once everything else
    # above has succeeded - its presence is exactly what the re-migration
    # guard at the top of this function checks for) ---------------------------
    _gm_emmc_assert_mounted "$emmc_part" || { _gm_emmc_cleanup; return 1; }
    mkdir -p "$GM_EMMC_MNT/etc/geomaxima" || { geomaxima_emmc_die "Could not create /etc/geomaxima on the eMMC target."; _gm_emmc_cleanup; return 1; }
    {
        echo "migrated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "migrated_from=$root_part"
        echo "migrated_to=$emmc_part"
    } > "$GM_EMMC_MNT/$GM_EMMC_MARKER_PATH" || { geomaxima_emmc_die "Could not write the migration marker."; _gm_emmc_cleanup; return 1; }

    sync
    _gm_emmc_cleanup

    # --- 11. Final check ---------------------------------------------------
    e2fsck -fn "$emmc_part" || { geomaxima_emmc_die "Final filesystem check failed!"; return 1; }
    local files
    files=$(dumpe2fs -h "$emmc_part" 2>/dev/null | awk -F: '/Inode count/{t=$2} /Free inodes/{f=$2} END{print t-f}')
    geomaxima_emmc_log "Files on eMMC: $files"

    # Exposed to the caller (install.sh) so it never needs to re-scan
    # /sys/block to figure out which eMMC disk/partition was used.
    GM_EMMC_RESULT_DISK="$emmc"
    GM_EMMC_RESULT_PART="$emmc_part"

    echo
    geomaxima_emmc_log "DONE. eMMC at $emmc_part is ready."
    geomaxima_emmc_log "Log: $GM_EMMC_LOG"
    return 0
}

# geomaxima_emmc_migrate(): public entry point. Redirects stdout/stderr to
# both the console and $GM_EMMC_LOG for the duration of the call ONLY -
# fd 3/4 save the real stdout/stderr first and restore them afterward,
# regardless of _gm_emmc_migrate_impl()'s result. Without this, `exec >
# >(tee ...)` would permanently redirect the CALLING shell's (install.sh's)
# stdout/stderr for the rest of its run, not just for the duration of this
# function - `exec` changes the current shell's file descriptors for good,
# it is not scoped to the function like a per-command redirect would be.
geomaxima_emmc_migrate() {
    exec 3>&1 4>&2
    exec > >(tee -a "$GM_EMMC_LOG") 2>&1

    _gm_emmc_migrate_impl "$@"
    local rc=$?

    exec 1>&3 2>&4 3>&- 4>&-
    return "$rc"
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
# boot0_sdcard.fex's known 8K offset - see this file's own header comment)
# up to, but not including, wherever the SD's root partition actually
# starts, so the filesystem itself is never touched.
#
# Return codes: 0 = wiped successfully, 1 = failed (caller must NOT reboot
# in this case - see install.sh's handling).
geomaxima_wipe_sd_bootloader() {
    local sd_part sd_disk sd_name
    if [[ -n "${GM_TEST_ROOT_PART:-}" ]]; then
        sd_part="$GM_TEST_ROOT_PART"
    else
        sd_part=$(findmnt -no SOURCE / 2>/dev/null || true)
    fi
    [[ -n "$sd_part" ]] || { geomaxima_emmc_die "Could not determine the SD root partition."; return 1; }
    sd_disk=/dev/$(lsblk -no PKNAME "$sd_part" 2>/dev/null || true)
    sd_name=$(basename "$sd_disk")
    [[ "$(cat "$GM_SYSFS/block/$sd_name/device/type" 2>/dev/null)" == "SD" ]] \
        || { geomaxima_emmc_die "$sd_disk does not report as an SD card - refusing to wipe it."; return 1; }

    local sd_part_name sd_part_start_sectors sd_part_start_k
    sd_part_name=$(basename "$sd_part")
    sd_part_start_sectors=$(cat "$GM_SYSFS/block/$sd_name/$sd_part_name/start" 2>/dev/null || echo 0)
    sd_part_start_k=$(( sd_part_start_sectors / 2 ))
    if (( sd_part_start_k <= 8 )); then
        geomaxima_emmc_die "SD root partition starts at ${sd_part_start_k}K, at or below the 8K boot0 offset - refusing to wipe (would touch the filesystem)."
        return 1
    fi
    local wipe_count_k=$(( sd_part_start_k - 8 ))

    geomaxima_emmc_warn "Erasing SD bootloader area on $sd_disk: 8K-${sd_part_start_k}K (${wipe_count_k}K), leaving the filesystem (starts at ${sd_part_start_k}K) untouched."
    dd if=/dev/zero of="$sd_disk" bs=1024 seek=8 count="$wipe_count_k" conv=fsync status=none \
        || { geomaxima_emmc_die "dd failed while erasing the SD bootloader area."; return 1; }
    sync
    geomaxima_emmc_log "SD bootloader area erased. The board should now fall through to eMMC on next boot (UNVERIFIED on this hardware - confirm before relying on this in production)."
    return 0
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
    rc=$?
    case "$rc" in
        0) exit 0 ;;
        2) echo "eMMC already prepared - nothing to do." >&2; exit 0 ;;
        *) echo "Migration failed (exit $rc) - see $GM_EMMC_LOG" >&2; exit 1 ;;
    esac
fi
