#!/bin/bash
################################################################################
# GeoMaxima Fully Automated Installation with Git + OTA Updates
################################################################################
# Usage:
#   curl -sSL https://raw.githubusercontent.com/peshovp/GeoMaxima-BS/master/install_with_git.sh | sudo bash
#
# OR manually:
#   wget https://raw.githubusercontent.com/peshovp/GeoMaxima-BS/master/install_with_git.sh
#   sudo bash install_with_git.sh
#
# This script will:
#   1. Check for GitHub Personal Access Token
#   2. Setup .netrc if needed
#   3. Clone GeoMaxima repo
#   4. Install everything
#   5. Configure passwordless sudo for OTA updates
################################################################################

set -e

REPO_URL="https://github.com/peshovp/GeoMaxima-BS.git"
REPO_NAME="GeoMaxima"
INSTALL_USER="${SUDO_USER:-$(whoami)}"
USER_HOME=$(eval echo "~${INSTALL_USER}")
NETRC_FILE="${USER_HOME}/.netrc"

echo "╔═══════════════════════════════════════════════════════╗"
echo "║                                                       ║"
echo "║         GeoMaxima Fully Automated Installer          ║"
echo "║                                                       ║"
echo "║         Git + OTA Updates Setup                      ║"
echo "║                                                       ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""

# Detect user
echo "[→] Detected user: ${INSTALL_USER}"
echo "[→] User home: ${USER_HOME}"

# Check if RTKBase is installed
echo "[→] Checking for RTKBase..."
if [ ! -d "${USER_HOME}/rtkbase" ]; then
    echo "[✗] RTKBase not found at ${USER_HOME}/rtkbase"
    echo "[!] Please install RTKBase first:"
    echo "    cd ~ && git clone https://github.com/stefal/rtkbase.git && cd rtkbase && ./install.sh"
    exit 1
fi
echo "[✓] RTKBase found"

# Setup .netrc for private repo access
echo ""
echo "[→] Checking GitHub authentication..."

if [ -f "${NETRC_FILE}" ]; then
    echo "[✓] .netrc already exists"
    
    # Test if it works
    if su - "${INSTALL_USER}" -c "git ls-remote ${REPO_URL} HEAD >/dev/null 2>&1"; then
        echo "[✓] GitHub authentication works!"
    else
        echo "[!] Existing .netrc doesn't work for this repo"
        echo "[!] You may need to update it manually"
    fi
else
    echo "[!] .netrc not found - GitHub Personal Access Token needed"
    echo ""
    echo "┌─────────────────────────────────────────────────────────┐"
    echo "│ This repo is PRIVATE and requires authentication       │"
    echo "│                                                         │"
    echo "│ Create a Personal Access Token:                        │"
    echo "│   1. Go to: https://github.com/settings/tokens         │"
    echo "│   2. Generate new token (classic)                      │"
    echo "│   3. Select scope: ✓ repo (full control)              │"
    echo "│   4. Copy the token (starts with ghp_...)             │"
    echo "└─────────────────────────────────────────────────────────┘"
    echo ""
    
    # Prompt for token
    read -sp "Enter your GitHub Personal Access Token (or press Enter to skip): " GITHUB_TOKEN
    echo ""
    
    if [ -n "${GITHUB_TOKEN}" ]; then
        echo "[→] Creating .netrc file..."
        
        # Create .netrc
        cat > "${NETRC_FILE}" << EOF
machine github.com
login peshovp
password ${GITHUB_TOKEN}
EOF
        
        # Set proper permissions
        chmod 600 "${NETRC_FILE}"
        chown "${INSTALL_USER}:${INSTALL_USER}" "${NETRC_FILE}"
        
        echo "[✓] .netrc created and secured"
        
        # Test authentication
        if su - "${INSTALL_USER}" -c "git ls-remote ${REPO_URL} HEAD >/dev/null 2>&1"; then
            echo "[✓] GitHub authentication successful!"
        else
            echo "[✗] Authentication failed - check your token"
            echo "[!] You can continue without OTA updates"
            echo "[!] Or fix .netrc manually later"
        fi
    else
        echo "[!] Skipping .netrc setup"
        echo "[!] OTA updates will NOT work without authentication"
        echo "[!] You can configure it later with: sudo bash install_with_git.sh"
    fi
fi

# Clone or update repository
echo ""
echo "[→] Setting up GeoMaxima repository..."

if [ -d "${USER_HOME}/${REPO_NAME}" ]; then
    echo "[✓] Repository already exists at ${USER_HOME}/${REPO_NAME}"
    
    # Update it
    echo "[→] Pulling latest changes..."
    cd "${USER_HOME}/${REPO_NAME}"
    
    su - "${INSTALL_USER}" -c "cd ${USER_HOME}/${REPO_NAME} && git stash && git pull origin master" || {
        echo "[!] Git pull failed - continuing with existing version"
    }
else
    echo "[→] Cloning repository..."
    
    su - "${INSTALL_USER}" -c "cd ${USER_HOME} && git clone ${REPO_URL} ${REPO_NAME}" || {
        echo "[✗] Git clone failed!"
        echo "[!] Check your .netrc configuration"
        echo "[!] Or use ZIP installation: install_from_zip.sh"
        exit 1
    }
    
    echo "[✓] Repository cloned to ${USER_HOME}/${REPO_NAME}"
fi

# Run installation
echo ""
echo "[→] Running GeoMaxima installation..."
cd "${USER_HOME}/${REPO_NAME}"

bash install_local.sh

# Configure passwordless sudo for OTA updates
echo ""
echo "[→] Configuring passwordless sudo for OTA updates..."

SUDOERS_FILE="/etc/sudoers.d/geomaxima-ota"

if [ ! -f "${SUDOERS_FILE}" ]; then
    cat > "${SUDOERS_FILE}" << EOF
# GeoMaxima OTA Update and Auto Survey permissions
# Allows web service to restart itself and manage RTKBase services
${INSTALL_USER} ALL=(ALL) NOPASSWD: /bin/systemctl restart rtkbase_web
${INSTALL_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart rtkbase_web

# Auto Survey: restart str2str services after coordinate update
${INSTALL_USER} ALL=(ALL) NOPASSWD: /bin/systemctl restart str2str_tcp.service
${INSTALL_USER} ALL=(ALL) NOPASSWD: /bin/systemctl restart str2str_ntrip_A.service
${INSTALL_USER} ALL=(ALL) NOPASSWD: /bin/systemctl restart str2str_ntrip_B.service
${INSTALL_USER} ALL=(ALL) NOPASSWD: /bin/systemctl restart str2str_rtcm_svr.service
${INSTALL_USER} ALL=(ALL) NOPASSWD: /bin/systemctl restart str2str_rtcm_serial.service
${INSTALL_USER} ALL=(ALL) NOPASSWD: /bin/systemctl restart str2str_local_ntrip_caster.service
${INSTALL_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart str2str_tcp.service
${INSTALL_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart str2str_ntrip_A.service
${INSTALL_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart str2str_ntrip_B.service
${INSTALL_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart str2str_rtcm_svr.service
${INSTALL_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart str2str_rtcm_serial.service
${INSTALL_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart str2str_local_ntrip_caster.service

# File logging management
${INSTALL_USER} ALL=(ALL) NOPASSWD: /bin/systemctl stop str2str_file
${INSTALL_USER} ALL=(ALL) NOPASSWD: /bin/systemctl start str2str_file
${INSTALL_USER} ALL=(ALL) NOPASSWD: /bin/systemctl enable str2str_file
${INSTALL_USER} ALL=(ALL) NOPASSWD: /bin/systemctl disable str2str_file
${INSTALL_USER} ALL=(ALL) NOPASSWD: /bin/systemctl status str2str_file
${INSTALL_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop str2str_file
${INSTALL_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl start str2str_file
${INSTALL_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl enable str2str_file
${INSTALL_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl disable str2str_file
${INSTALL_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl status str2str_file
EOF
    
    chmod 440 "${SUDOERS_FILE}"
    
    # Validate syntax
    if visudo -c -f "${SUDOERS_FILE}" >/dev/null 2>&1; then
        echo "[✓] Passwordless sudo configured"
    else
        echo "[✗] Sudoers syntax error - removing for safety"
        rm -f "${SUDOERS_FILE}"
    fi
else
    echo "[✓] Passwordless sudo already configured"
fi

# Get version
VERSION=$(cat "${USER_HOME}/${REPO_NAME}/VERSION" 2>/dev/null || echo "unknown")
IP_ADDR=$(hostname -I | awk '{print $1}')

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║                                                       ║"
echo "║            ✅ Installation Complete!                 ║"
echo "║                                                       ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""
echo "[✓] 📦 GeoMaxima v${VERSION} installed"
echo ""
echo "[✓] ⚡ Access Points:"
echo "     Dashboard:    http://${IP_ADDR}/geomaxima"
echo "     WireGuard:    http://${IP_ADDR}/geomaxima/wireguard"
echo "     Auto Survey:  http://${IP_ADDR}/geomaxima/survey"
echo "     OTA Update:   http://${IP_ADDR}/geomaxima/update"
echo ""

if [ -f "${NETRC_FILE}" ]; then
    echo "[✓] 🔄 OTA Updates: ENABLED"
    echo "     Updates can be installed via web UI"
else
    echo "[!] 🔄 OTA Updates: DISABLED"
    echo "     Configure .netrc to enable automatic updates"
    echo "     Run this script again to configure"
fi

echo ""
echo "[✓] 🔍 Check Status:"
echo "     sudo systemctl status rtkbase_web"
echo "     sudo journalctl -u rtkbase_web -f"
echo ""
echo "[✓] 📂 Installed at:"
echo "     Git Repo:  ${USER_HOME}/${REPO_NAME}"
echo "     Deployed:  ${USER_HOME}/rtkbase/geomaxima"
echo ""
