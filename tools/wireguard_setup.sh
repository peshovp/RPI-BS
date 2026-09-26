#!/usr/bin/env bash
# =============================================================================
#  tools/wireguard_setup.sh
#  Meant to be SOURCED. Defines geomaxima_install_wireguard(), the ONE place
#  that installs WireGuard tooling for this station - install.sh,
#  addons/tools/perform_update.sh, and addons/features/wireguard_client.py
#  (via this same shell helper, not a separate Python re-implementation) all
#  call this instead of duplicating the logic.
#
#  HARD RULE - NEVER VIOLATE THIS: never install a kernel package
#  (linux-image-*), a DKMS package (*-dkms), or the Debian `wireguard`
#  METAPACKAGE to obtain WireGuard. Install ONLY `wireguard-tools`, and
#  `wireguard-go` (userspace) if the running kernel lacks in-kernel
#  WireGuard support.
#
#  CONFIRMED LIVE ROOT CAUSE (Orange Pi 4 Pro+, Allwinner A733/sun60iw2):
#  the Debian `wireguard` package is only a thin metapackage - it Depends
#  on `wireguard-modules | wireguard-dkms`, and `wireguard-modules` is
#  PROVIDED ONLY by Debian's own linux-image-* kernel packages (including
#  linux-image-rt-arm64). Installing `wireguard` therefore pulls in a
#  Debian-origin kernel package as a dependency - on a board with its own
#  vendor kernel (like the A733's 6.6.98-vendor-sun60iw2, confirmed to
#  have `# CONFIG_WIREGUARD is not set` and no wireguard module at all),
#  that Debian kernel's postinst repoints /boot/uInitrd at itself while
#  /boot/Image and /boot/dtb keep pointing at the vendor kernel - the
#  SAME unbootable combination independently confirmed and fixed for the
#  general case by tools/armbian_kernel_pin.sh. This is almost certainly
#  what caused the original brick this whole Armbian/A733 support effort
#  traces back to: apt installing `wireguard` pulled in
#  linux-image-rt-arm64 as a dependency, and the pin (which only exists to
#  block exactly this) hadn't been written yet at that point.
#
#  The fix does NOT require any station-logic changes: every WireGuard use
#  on this station goes through `wg-quick@wg0` (web_app/server.py,
#  addons/features/wireguard_client.py, addons/features/watchdog/
#  monitors/network_monitor.py), and `wg-quick` itself already falls back
#  to the userspace `wireguard-go` implementation automatically whenever
#  the kernel has no native WireGuard support - it does not care which
#  backend actually created the interface.
#
#  Idempotent and WARNING-ONLY on failure: WireGuard is an optional
#  feature for this station (remote management tunnel), not required for
#  its core RTCM/GNSS function - a WireGuard setup failure must never fail
#  the whole install/update.
#
#  Usage:
#    source tools/wireguard_setup.sh
#    geomaxima_install_wireguard
# =============================================================================

geomaxima_install_wireguard() {
    echo "Installing WireGuard tooling (wireguard-tools only - never the 'wireguard' metapackage, see tools/wireguard_setup.sh)..."

    if ! apt-get install -y -qq wireguard-tools; then
        echo "WARNING: failed to install wireguard-tools - WireGuard will not be available. This does not affect RTCM/GNSS functions." >&2
        return 0
    fi

    # Test whether the RUNNING kernel actually has native WireGuard
    # support, rather than assuming from board/distro - the most reliable
    # test is trying to actually create a WireGuard-type interface, which
    # only succeeds if the kernel module is present/loadable. A
    # throwaway interface name is used and deleted immediately after.
    if ip link add gm-wgtest type wireguard 2>/dev/null; then
        ip link del gm-wgtest 2>/dev/null || true
        echo "✓ Kernel has native WireGuard support - wireguard-tools is sufficient."
        return 0
    fi

    echo "Kernel has no native WireGuard support (confirmed via 'ip link add type wireguard' failing) - installing userspace wireguard-go fallback..."
    if apt-get install -y -qq wireguard-go; then
        echo "✓ Kernel has no WireGuard, using userspace wireguard-go."
    else
        echo "WARNING: kernel has no native WireGuard support AND wireguard-go install failed - WireGuard will not be usable on this station. This does not affect RTCM/GNSS functions." >&2
    fi
    return 0
}
