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

echo "============================================================================"
echo "STAGE 1/5: System Update & Prerequisites"
echo "============================================================================"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

# --- Defensive check: PREEMPT_RT kernel / boot-symlink consistency ---
# Warning-only, never modifies anything. On Armbian (and other non-Raspberry-Pi-OS
# boards using Debian's generic kernel package mechanism), installing a
# linux-image-*-rt-arm64 package alongside the board's vendor kernel is a known
# hazard: the RT kernel's postinst updates the /boot/uInitrd symlink to point at
# itself, but does NOT update /boot/Image or /boot/dtb, which keep pointing at the
# vendor kernel (the one with the correct SoC drivers/device-tree). The result is
# U-Boot loading a vendor kernel with an RT initrd - an incompatible combination
# that causes a full boot failure. Confirmed live on an Orange Pi 4 Pro station
# (Allwinner A733, Armbian vendor kernel 6.6.98-vendor-sun60iw2) after
# linux-image-6.12.107+deb13-rt-arm64 ended up installed alongside it.
# RTKBase does not require PREEMPT_RT for GNSS processing - this check does not
# assert why an RT kernel is present, only that if one is, /boot/Image, /boot/dtb,
# and /boot/uInitrd must all resolve to the SAME kernel version before rebooting.
if dpkg -l 2>/dev/null | grep -q -- '-rt-arm64'; then
    echo "WARNING: a PREEMPT_RT (rt-arm64) kernel package is installed on this system." >&2
    echo "On Armbian/non-Raspberry-Pi-OS boards this can desync the /boot/Image, /boot/dtb," >&2
    echo "and /boot/uInitrd symlinks (each may end up pointing at a DIFFERENT kernel after" >&2
    echo "the RT kernel's postinst runs), which causes a hard boot failure at next reboot." >&2
    echo "RTKBase does not require PREEMPT_RT for GNSS processing." >&2
    echo "Before rebooting, verify all three point at the SAME kernel version:" >&2
    echo "  ls -la /boot/Image /boot/dtb /boot/uInitrd" >&2
    echo "This script will NOT modify these symlinks automatically - fix manually if inconsistent." >&2
fi

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

# Checks whether BASH_SOURCE[0] points at a real file on disk that is part of
# an actual RPI-BS checkout. Under "curl | sudo bash", BASH_SOURCE[0] is
# something like "bash" or "/dev/stdin" -- not a real path -- so this
# correctly (and silently) fails in that case, it isn't an error condition.
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
        git -C "$INSTALL_DIR" pull --ff-only || { log "ERROR: git pull --ff-only failed in $INSTALL_DIR"; exit 1; }
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
fi

cd "$SCRIPT_DIR"

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

echo ""
echo "============================================================================"
echo "STAGE 5/5: INSTALLATION COMPLETE! Please review the status above."
echo "============================================================================"
echo "Remember to check the logs and test connectivity."
