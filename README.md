# GeoMaxima

Security-hardened GNSS/RTK base station software for Raspberry Pi, built on [Stefal/rtkbase](https://github.com/Stefal/rtkbase).

## Install

On a clean Raspberry Pi OS Trixie (aarch64):

```bash
curl -fsSL https://raw.githubusercontent.com/peshovp/RPI-BS/main/install.sh | sudo bash
```

This single command:
1. Updates the system and installs prerequisites
2. Applies security hardening (UFW, fail2ban, SSH lockdown)
3. Installs RTKBase with GeoMaxima's custom features: OTA updates, audit logging, Auto Survey-In, and authentication

After installation, access the web interface at `http://<pi-ip-address>`.

## Update

Updates can be applied directly from the web UI (Settings → Check for Updates → Update Now), or manually:

```bash
cd RPI-BS && sudo ./addons/tools/perform_update.sh "$(pwd)" "$(pwd)/.update_status.json"
```

## Armbian limitations (Orange Pi 4 Pro+ and similar boards)

- **WireGuard runs in userspace on boards whose vendor kernel has no
  native WireGuard support** (confirmed on the Orange Pi 4 Pro+'s
  Allwinner A733 vendor kernel, `6.6.98-vendor-sun60iw2` -
  `CONFIG_WIREGUARD` is not set). The installer detects this automatically
  and installs the `wireguard-go` userspace implementation instead, which
  `wg-quick` uses transparently - no station configuration changes are
  needed, and the remote-management WireGuard tunnel works the same way.
  Userspace WireGuard is somewhat slower than the in-kernel module, but
  more than sufficient for the RTCM/management traffic this station
  actually sends over it.
  - The installer (and every OTA update) **never installs the Debian
    `wireguard` metapackage** to get there - that package depends on
    `wireguard-modules`, which is only provided by Debian's own
    `linux-image-*` kernel packages, and installing one of those alongside
    a board's own vendor kernel produces an unbootable combination (a
    Debian kernel's postinst repoints `/boot/uInitrd` at itself while
    `/boot/Image`/`/boot/dtb` keep pointing at the vendor kernel). See
    `tools/wireguard_setup.sh` for the full technical detail.
  - Long-term fix: ask Armbian to enable `CONFIG_WIREGUARD` in the
    sun60iw2 vendor kernel config, which would make this station-side
    workaround unnecessary.
- **The `openresolv` package is never installed on boards where
  systemd-resolved or NetworkManager is already managing DNS** (this
  includes the Orange Pi 4 Pro+'s Armbian image, which uses
  systemd-networkd + systemd-resolved). Confirmed live: `openresolv` and
  `systemd-resolved` conflict with each other on Debian trixie, so a plain
  `apt-get install openresolv` silently REMOVED the active
  systemd-resolved package, leaving the board with no working DNS at all.
  The installer now installs `openresolv` only when no resolver manager is
  already active and no `resolvconf` implementation is already present. On
  a board that already has an `openresolv` or Debian-`resolvconf`
  installation, the DNS-fallback step (adding 8.8.8.8/1.1.1.1 as
  secondary resolvers) writes to whichever mechanism that specific
  implementation actually reads - the two are not interoperable. See
  `tools/dns_setup.sh` for the full technical detail.
