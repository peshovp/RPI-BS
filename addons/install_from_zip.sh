#!/bin/bash
################################################################################
# GeoMaxima Installation from ZIP Archive
################################################################################
# Usage:
#   1. Download latest release ZIP from GitHub
#   2. Extract: unzip GeoMaxima-BS-main.zip
#   3. cd GeoMaxima-BS-main
#   4. sudo bash install_from_zip.sh
#
# This script does NOT require git or GitHub authentication.
# Perfect for offline/air-gapped installations.
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_USER="${SUDO_USER:-$(whoami)}"
USER_HOME=$(eval echo "~${INSTALL_USER}")

echo "╔═══════════════════════════════════════════════════════╗"
echo "║                                                       ║"
echo "║         GeoMaxima ZIP Installer                      ║"
echo "║                                                       ║"
echo "║         No git required - offline install            ║"
echo "║                                                       ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""

# Detect user
echo "[→] Detected user: ${INSTALL_USER}"
echo "[→] User home: ${USER_HOME}"

# Find RTKBase
echo "[→] Searching for RTKBase installation..."
RTKBASE_PATH=""
if [ -d "${USER_HOME}/rtkbase" ]; then
    RTKBASE_PATH="${USER_HOME}/rtkbase"
elif [ -d "/home/${INSTALL_USER}/rtkbase" ]; then
    RTKBASE_PATH="/home/${INSTALL_USER}/rtkbase"
else
    echo "[✗] RTKBase not found!"
    echo "[!] Please install RTKBase first: https://github.com/stefal/rtkbase"
    exit 1
fi

echo "[✓] Found RTKBase at ${RTKBASE_PATH}"

# Version info
VERSION=$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null || echo "unknown")
echo "[✓] Installing GeoMaxima v${VERSION} from ${SCRIPT_DIR}"

# Run main installation
echo ""
echo "[→] Running installation..."
cd "${SCRIPT_DIR}"
bash install_local.sh

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║                                                       ║"
echo "║            ✅ ZIP Installation Complete!             ║"
echo "║                                                       ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""
echo "[✓] GeoMaxima v${VERSION} installed"
echo "[✓] Access: http://$(hostname -I | awk '{print $1}')/geomaxima"
echo ""
echo "[!] Note: OTA updates require git repository"
echo "[!] To enable OTA updates, run: sudo bash install_with_git.sh"
echo ""
