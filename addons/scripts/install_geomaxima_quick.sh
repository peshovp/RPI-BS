#!/bin/bash

################################################################################
# GeoMaxima Quick Install (for existing RTKBase)
# 
# Installs GeoMaxima on existing RTKBase installation
#
# Usage:
#   wget -O - https://raw.githubusercontent.com/peshovp/GeoMaxima-BS/master/install_geomaxima_quick.sh | sudo bash
################################################################################

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
GEOMAXIMA_REPO="https://github.com/peshovp/GeoMaxima-BS.git"
GEOMAXIMA_BRANCH="master"

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    log_error "Please run with sudo"
    exit 1
fi

# Detect RTKBase user
if [ -n "${SUDO_USER}" ]; then
    RTKBASE_USER="${SUDO_USER}"
else
    log_error "Cannot detect user. Run with sudo as: sudo ./install_geomaxima_quick.sh"
    exit 1
fi

RTKBASE_PATH="/home/${RTKBASE_USER}/rtkbase"
GEOMAXIMA_PATH="${RTKBASE_PATH}/geomaxima"

# Check if RTKBase exists
if [ ! -d "${RTKBASE_PATH}" ]; then
    log_error "RTKBase not found at ${RTKBASE_PATH}"
    log_error "Please install RTKBase first or use full install script"
    exit 1
fi

log_info "Found RTKBase at ${RTKBASE_PATH}"

# Backup existing geomaxima if exists
if [ -d "${GEOMAXIMA_PATH}" ]; then
    BACKUP="${GEOMAXIMA_PATH}.backup.$(date +%Y%m%d_%H%M%S)"
    log_warn "Backing up existing GeoMaxima to ${BACKUP}"
    mv "${GEOMAXIMA_PATH}" "${BACKUP}"
fi

# Clone GeoMaxima
log_info "Cloning GeoMaxima..."
cd "${RTKBASE_PATH}"
sudo -u "${RTKBASE_USER}" git clone --branch "${GEOMAXIMA_BRANCH}" "${GEOMAXIMA_REPO}" geomaxima

# Set permissions
log_info "Setting permissions..."
chown -R "${RTKBASE_USER}:${RTKBASE_USER}" "${GEOMAXIMA_PATH}"
chmod +x "${GEOMAXIMA_PATH}/geomaxima_update.sh"

# Install dependencies
if [ -f "${GEOMAXIMA_PATH}/requirements-geomaxima.txt" ]; then
    log_info "Installing Python dependencies..."
    pip3 install -r "${GEOMAXIMA_PATH}/requirements-geomaxima.txt" --extra-index-url https://www.piwheels.org/simple 2>/dev/null || true
fi

# Integrate with RTKBase
RTKBASE_SERVER="${RTKBASE_PATH}/web_app/server.py"
if ! grep -q "geomaxima" "${RTKBASE_SERVER}"; then
    log_info "Integrating with RTKBase..."
    sed -i '/update_std_user(services_list)/a\
        \
        # Initialize GeoMaxima\
        try:\
            sys.path.insert(0, rtkbase_path)\
            from geomaxima.controller import init_geomaxima\
            geomaxima_controller = init_geomaxima(app)\
            print(f"GeoMaxima v{geomaxima_controller.version} loaded successfully")\
        except Exception as e:\
            print(f"GeoMaxima error: {e}")' "${RTKBASE_SERVER}"
fi

RTKBASE_BASE_HTML="${RTKBASE_PATH}/web_app/templates/base.html"
if ! grep -q "GeoMaxima" "${RTKBASE_BASE_HTML}"; then
    sed -i '/<li class="nav-item">{{ render_nav_item.*logs_page/a\
        <li class="nav-item">{{ render_nav_item('"'"'geomaxima.index'"'"', '"'"'GeoMaxima'"'"', use_li=True) }}</li>' "${RTKBASE_BASE_HTML}"
fi

# Restart service
log_info "Restarting RTKBase web service..."
systemctl restart rtkbase_web.service
sleep 2

if systemctl is-active --quiet rtkbase_web.service; then
    IP=$(hostname -I | awk '{print $1}')
    echo ""
    log_info "✅ GeoMaxima installed successfully!"
    echo ""
    log_info "Access: http://${IP}/geomaxima"
    log_info "WireGuard: http://${IP}/geomaxima/wireguard"
    echo ""
else
    log_error "Service failed to start. Check logs:"
    log_error "sudo journalctl -u rtkbase_web -n 50"
fi
