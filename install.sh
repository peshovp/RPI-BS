#!/usr/bin/env bash
# =============================================================================
# install.sh - Master installation script for RTKBase on Raspberry Pi OS Trixie
# =============================================================================
# MUST be run as root or with sudo.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --- 1. Banner + root/sudo check ---
echo "============================================================================"
echo "          RTKBase Master Installation Script"
echo "============================================================================"
echo "This script performs a full, clean installation of RTKBase on Raspberry Pi OS Trixie."
echo "WARNING: This process requires root privileges and will modify system files."
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (or using sudo)."
    exit 1
fi

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
