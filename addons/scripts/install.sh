#!/bin/bash

################################################################################
# GeoMaxima Smart Installer
# 
# Automatically detects and installs:
# - RTKBase (if not present) + GeoMaxima
# - GeoMaxima only (if RTKBase already exists)
#
# Usage:
#   wget -O - https://raw.githubusercontent.com/peshovp/GeoMaxima-BS/master/install.sh | sudo bash
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
RTKBASE_REPO="https://github.com/Stefal/rtkbase.git"
RTKBASE_ALREADY_INSTALLED=false

log_info() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_step() { echo -e "${BLUE}[→]${NC} $1"; }

print_banner() {
    echo -e "${BLUE}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════╗
║                                                       ║
║           GeoMaxima Smart Installer                  ║
║                                                       ║
║     Auto-detects and installs what you need          ║
║                                                       ║
╚═══════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then 
        log_error "Please run with sudo"
        exit 1
    fi
}

detect_user() {
    log_step "Detecting user..."
    
    if [ -n "${SUDO_USER}" ]; then
        RTKBASE_USER="${SUDO_USER}"
        log_info "Detected user: ${RTKBASE_USER}"
    else
        log_error "Cannot detect user. Run with sudo: sudo bash install.sh"
        exit 1
    fi
    
    RTKBASE_PATH="/home/${RTKBASE_USER}/rtkbase"
    GEOMAXIMA_PATH="${RTKBASE_PATH}/geomaxima"
}

check_rtkbase() {
    log_step "Checking for RTKBase installation..."
    
    if [ -d "${RTKBASE_PATH}" ]; then
        # Verify it's a valid RTKBase
        if [ -f "${RTKBASE_PATH}/web_app/server.py" ] && [ -f "${RTKBASE_PATH}/settings.conf" ]; then
            log_info "✅ Found existing RTKBase at ${RTKBASE_PATH}"
            
            if [ -f "${RTKBASE_PATH}/version.txt" ]; then
                VERSION=$(cat "${RTKBASE_PATH}/version.txt")
                log_info "RTKBase version: ${VERSION}"
            fi
            
            RTKBASE_ALREADY_INSTALLED=true
        else
            log_warn "Directory exists but RTKBase incomplete"
            RTKBASE_ALREADY_INSTALLED=false
        fi
    else
        log_info "RTKBase not found - will install it first"
        RTKBASE_ALREADY_INSTALLED=false
    fi
}

check_requirements() {
    log_step "Checking requirements..."
    
    local missing=""
    
    for cmd in git wget systemctl; do
        if ! command -v $cmd &> /dev/null; then
            missing="$missing $cmd"
        fi
    done
    
    if [ -n "$missing" ]; then
        log_warn "Missing:$missing - installing..."
        apt-get update -qq
        apt-get install -y git wget systemd 2>&1 | grep -v "^Reading"
    fi
    
    log_info "All requirements met"
}

backup_existing() {
    if [ -d "${GEOMAXIMA_PATH}" ]; then
        BACKUP="${GEOMAXIMA_PATH}.backup.$(date +%Y%m%d_%H%M%S)"
        log_warn "Backing up existing GeoMaxima to ${BACKUP}"
        mv "${GEOMAXIMA_PATH}" "${BACKUP}"
    fi
}

install_rtkbase() {
    log_step "Installing RTKBase..."
    
    cd "/home/${RTKBASE_USER}"
    
    # Clone RTKBase
    log_info "Downloading RTKBase..."
    sudo -u "${RTKBASE_USER}" git clone --depth 1 "${RTKBASE_REPO}" rtkbase 2>&1 | grep -v "^Cloning"
    
    cd rtkbase
    
    # Run RTKBase installer
    log_info "Running RTKBase installation (this may take several minutes)..."
    ./tools/install.sh --all 2>&1 | while IFS= read -r line; do
        echo "  $line" | head -100
    done
    
    log_info "✅ RTKBase installed successfully"
}

install_geomaxima() {
    log_step "Installing GeoMaxima..."
    
    cd "${RTKBASE_PATH}"
    
    # Clone GeoMaxima
    log_info "Downloading GeoMaxima..."
    sudo -u "${RTKBASE_USER}" git clone --branch "${GEOMAXIMA_BRANCH}" "${GEOMAXIMA_REPO}" geomaxima 2>&1 | grep -v "^Cloning"
    
    # Set permissions
    chown -R "${RTKBASE_USER}:${RTKBASE_USER}" "${GEOMAXIMA_PATH}"
    chmod +x "${GEOMAXIMA_PATH}/geomaxima_update.sh" 2>/dev/null || true
    
    # Install Python dependencies
    if [ -f "${GEOMAXIMA_PATH}/requirements-geomaxima.txt" ]; then
        log_info "Installing Python dependencies..."
        pip3 install -q -r "${GEOMAXIMA_PATH}/requirements-geomaxima.txt" --extra-index-url https://www.piwheels.org/simple 2>/dev/null || true
    fi
    
    log_info "✅ GeoMaxima installed successfully"
}

integrate_geomaxima() {
    log_step "Integrating GeoMaxima with RTKBase..."
    
    local SERVER="${RTKBASE_PATH}/web_app/server.py"
    local BASE_HTML="${RTKBASE_PATH}/web_app/templates/base.html"
    
    # Modify server.py
    if ! grep -q "geomaxima" "${SERVER}"; then
        log_info "Modifying server.py..."
        sed -i '/update_std_user(services_list)/a\
        \
        # Initialize GeoMaxima\
        try:\
            sys.path.insert(0, rtkbase_path)\
            from geomaxima.controller import init_geomaxima\
            geomaxima_controller = init_geomaxima(app)\
            print(f"GeoMaxima v{geomaxima_controller.version} loaded successfully")\
        except Exception as e:\
            print(f"GeoMaxima error: {e}")' "${SERVER}"
    fi
    
    # Modify base.html
    if ! grep -q "GeoMaxima" "${BASE_HTML}"; then
        log_info "Adding GeoMaxima menu..."
        sed -i '/<li class="nav-item">{{ render_nav_item.*logs_page/a\
        <li class="nav-item">{{ render_nav_item('"'"'geomaxima.index'"'"', '"'"'GeoMaxima'"'"', use_li=True) }}</li>' "${BASE_HTML}"
    fi
    
    log_info "✅ Integration complete"
}

restart_services() {
    log_step "Restarting services..."
    
    systemctl restart rtkbase_web.service 2>/dev/null || true
    sleep 2
    
    if systemctl is-active --quiet rtkbase_web.service; then
        log_info "✅ Service started successfully"
    else
        log_warn "Service may not have started - check logs"
    fi
}

display_completion() {
    local IP=$(hostname -I | awk '{print $1}')
    
    echo ""
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║                                                       ║"
    echo "║            ✅ Installation Complete!                 ║"
    echo "║                                                       ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    if [ "${RTKBASE_ALREADY_INSTALLED}" = true ]; then
        log_info "📦 GeoMaxima added to existing RTKBase"
    else
        log_info "📦 RTKBase + GeoMaxima installed"
        echo ""
        log_info "🌐 RTKBase Access:"
        log_info "   http://${IP}"
        log_info "   User: admin / Pass: admin"
    fi
    
    echo ""
    log_info "⚡ GeoMaxima Access:"
    log_info "   Dashboard: http://${IP}/geomaxima"
    log_info "   WireGuard: http://${IP}/geomaxima/wireguard"
    echo ""
    log_info "🔄 Update GeoMaxima:"
    log_info "   sudo ${GEOMAXIMA_PATH}/geomaxima_update.sh"
    echo ""
    log_info "🔍 Check Status:"
    log_info "   sudo systemctl status rtkbase_web"
    echo ""
}

# Main installation flow
main() {
    print_banner
    
    check_root
    detect_user
    check_rtkbase
    check_requirements
    
    if [ "${RTKBASE_ALREADY_INSTALLED}" = true ]; then
        log_info "🎯 Mode: Quick Install (GeoMaxima only)"
        echo ""
        backup_existing
        install_geomaxima
        integrate_geomaxima
        restart_services
    else
        log_info "🎯 Mode: Full Install (RTKBase + GeoMaxima)"
        echo ""
        backup_existing
        install_rtkbase
        install_geomaxima
        integrate_geomaxima
        restart_services
    fi
    
    display_completion
}

# Run
main "$@"
