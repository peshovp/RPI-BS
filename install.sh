#!/usr/bin/env bash
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
echo "STAGE 1/4: Running Security Setup (tools/security_setup.sh)"
echo "============================================================================"
echo "NOTE: This script will prompt you for confirmation (e.g., enabling UFW)."

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
echo "STAGE 2/4: Running Upstream RTKBase Base Installation (tools/install.sh)"
echo "============================================================================"

if [ ! -L "rtkbase" ]; then
    ln -s . rtkbase
fi

./tools/install.sh --all repo --rtkbase-repo main --user "${SUDO_USER:-$USER}" --start-services

# --- 4. Final checklist ---
echo ""
echo "============================================================================"
echo "STAGE 3/4: Finalization and Checklist"
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
echo "STAGE 4/4: INSTALLATION COMPLETE! Please review the status above."
echo "============================================================================"
echo "Remember to check the logs and test connectivity."
