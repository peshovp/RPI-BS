#!/usr/bin/env bash
# =============================================================================
#  tools/armbian_kernel_pin.sh
#  Meant to be SOURCED. Defines geomaxima_apply_armbian_kernel_pin(), which
#  writes an apt preferences pin + apt-mark hold for Debian-origin kernel
#  packages, so `apt upgrade`/`apt full-upgrade` can never install a Debian
#  generic/RT kernel alongside an Armbian board's vendor kernel.
#
#  Confirmed live on an Orange Pi 4 Pro+ (Allwinner A733/sun60iw2): a
#  Debian-origin linux-image-*-rt-arm64 package got installed alongside the
#  Armbian vendor kernel. The RT kernel's postinst updated the /boot/uInitrd
#  symlink to point at itself, but /boot/Image and /boot/dtb kept pointing
#  at the vendor kernel (the only one with correct SoC drivers/device-tree),
#  producing an unbootable combination at next reboot.
#
#  apt-mark hold alone does NOT prevent this - it only holds packages that
#  are ALREADY installed from being upgraded/removed; it does not stop a
#  brand-new package from being installed for the first time. A preferences
#  pin (Pin-Priority: -1) is required to actually block the install.
#
#  Called from three places, all of which must reach the SAME state, which
#  is why this logic is factored into one shared, idempotent function:
#    - install.sh (fresh install, root partition) - before its `apt upgrade`
#    - tools/emmc-install-opi4pro.sh - written directly into the eMMC target
#      ($MNT), before its rsync, so the pin is present on first boot from
#      eMMC (writing it only to the SD source would never reach the eMMC)
#    - addons/tools/perform_update.sh (OTA) - re-applied every run, since a
#      user could remove/edit the pin file between OTA runs
#
#  Usage:
#    source tools/armbian_kernel_pin.sh
#    geomaxima_apply_armbian_kernel_pin              # applies to the running system
#    geomaxima_apply_armbian_kernel_pin "$MNT"        # applies under an alternate root
# =============================================================================

geomaxima_apply_armbian_kernel_pin() {
    local target_root="${1:-}"
    local pin_dir="${target_root}/etc/apt/preferences.d"
    local pin_file="$pin_dir/geomaxima-no-debian-kernel"

    mkdir -p "$pin_dir"
    cat > "$pin_file" <<'EOF'
# Added by RPI-BS (GeoMaxima) - see tools/armbian_kernel_pin.sh.
# Blocks apt from ever installing a Debian-origin kernel package alongside
# an Armbian board's vendor kernel (confirmed live: this combination is
# unbootable - see the comment in tools/armbian_kernel_pin.sh for details).
# This does NOT affect Armbian's own kernel packages (apt.armbian.com),
# only ones whose origin is deb.debian.org.
Package: linux-image-* linux-headers-* linux-kbuild-*
Pin: origin "deb.debian.org"
Pin-Priority: -1
EOF

    # Belt-and-suspenders: also hold any matching kernel packages that are
    # ALREADY installed on the running system (not meaningful under an
    # alternate root such as a not-yet-booted eMMC target, where dpkg's own
    # database is the running system's, not the target's - skip there).
    if [[ -z "$target_root" ]]; then
        local installed_kernel_pkgs
        installed_kernel_pkgs="$(dpkg -l 2>/dev/null | awk '/^ii/{print $2}' | grep -E '^linux-(image|headers|kbuild)-' || true)"
        if [[ -n "$installed_kernel_pkgs" ]]; then
            # shellcheck disable=SC2086
            apt-mark hold $installed_kernel_pkgs >/dev/null 2>&1 || true
        fi
    fi

    echo "✓ Armbian Debian-kernel apt pin written to ${pin_file}."
}
