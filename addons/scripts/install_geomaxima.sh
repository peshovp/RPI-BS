#!/bin/bash

################################################################################
# GeoMaxima Complete Installation Script
# 
# Automatically installs:
# 1. RTKBase (from official Stefal repository)
# 2. GeoMaxima extensions (from peshovp/GeoMaxima-BS)
#
# Usage:
#   wget -O - https://raw.githubusercontent.com/peshovp/GeoMaxima-BS/master/install_geomaxima.sh | sudo bash
#
# Or download and run:
#   wget https://raw.githubusercontent.com/peshovp/GeoMaxima-BS/master/install_geomaxima.sh
#   chmod +x install_geomaxima.sh
#   sudo ./install_geomaxima.sh
################################################################################

set -e  # Exit on error

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
RTKBASE_REPO="https://github.com/Stefal/rtkbase.git"
GEOMAXIMA_REPO="https://github.com/peshovp/GeoMaxima-BS.git"
GEOMAXIMA_BRANCH="master"
INSTALL_DIR="/home"
RTKBASE_USER=""

# Banner
print_banner() {
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║                                                           ║"
    echo "║     GeoMaxima Complete Installation Script               ║"
    echo "║                                                           ║"
    echo "║     RTKBase + GeoMaxima Extensions                       ║"
    echo "║                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        log_error "Please run this script with sudo or as root"
        exit 1
    fi
}

# Detect user
detect_user() {
    if [ -n "${SUDO_USER}" ]; then
        RTKBASE_USER="${SUDO_USER}"
    else
        log_warn "Cannot detect user. Please specify username:"
        read -r RTKBASE_USER
        if [ -z "${RTKBASE_USER}" ]; then
            log_error "Username cannot be empty"
            exit 1
        fi
    fi
    
    INSTALL_DIR="/home/${RTKBASE_USER}"
    RTKBASE_PATH="${INSTALL_DIR}/rtkbase"
    GEOMAXIMA_PATH="${RTKBASE_PATH}/geomaxima"
    
    log_info "Installation will use user: ${RTKBASE_USER}"
    log_info "RTKBase path: ${RTKBASE_PATH}"
    log_info "GeoMaxima path: ${GEOMAXIMA_PATH}"
}

# Check system requirements
check_requirements() {
    log_step "Checking system requirements..."
    
    # Check OS
    if [ ! -f /etc/os-release ]; then
        log_error "Cannot detect OS. This script requires Debian/Ubuntu based system."
        exit 1
    fi
    
    . /etc/os-release
    log_info "Detected OS: ${NAME} ${VERSION}"
    
    # Check architecture
    ARCH=$(uname -m)
    log_info "Architecture: ${ARCH}"
    
    # Check internet connection
    if ! ping -c 1 github.com &> /dev/null; then
        log_error "No internet connection. Please check your network."
        exit 1
    fi
    
    log_info "System requirements check passed"
}

# Backup existing installation
backup_existing() {
    if [ -d "${RTKBASE_PATH}" ]; then
        log_warn "Existing RTKBase installation found at ${RTKBASE_PATH}"
        read -p "Do you want to backup and continue? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            BACKUP_PATH="${RTKBASE_PATH}.backup.$(date +%Y%m%d_%H%M%S)"
            log_info "Creating backup at ${BACKUP_PATH}..."
            mv "${RTKBASE_PATH}" "${BACKUP_PATH}"
            log_info "Backup created successfully"
        else
            log_error "Installation cancelled by user"
            exit 1
        fi
    fi
}

# Install RTKBase
install_rtkbase() {
    log_step "Installing RTKBase..."
    
    cd "${INSTALL_DIR}"
    
    # Get latest RTKBase release
    log_info "Downloading RTKBase latest release..."
    sudo -u "${RTKBASE_USER}" wget https://github.com/Stefal/rtkbase/releases/latest/download/rtkbase.tar.gz -O rtkbase.tar.gz
    
    # Extract
    log_info "Extracting RTKBase..."
    sudo -u "${RTKBASE_USER}" tar -xzf rtkbase.tar.gz
    sudo -u "${RTKBASE_USER}" rm rtkbase.tar.gz
    
    cd "${RTKBASE_PATH}"
    
    # Run RTKBase installation
    log_info "Running RTKBase installation script..."
    log_warn "This will take several minutes. Please be patient..."
    
    # Install all components
    ./tools/install.sh --user="${RTKBASE_USER}" --all release
    
    if [ $? -eq 0 ]; then
        log_info "RTKBase installation completed successfully"
    else
        log_error "RTKBase installation failed"
        exit 1
    fi
}

# Install GeoMaxima
install_geomaxima() {
    log_step "Installing GeoMaxima extensions..."
    
    cd "${RTKBASE_PATH}"
    
    # Check if geomaxima already exists
    if [ -d "${GEOMAXIMA_PATH}" ]; then
        log_warn "GeoMaxima directory already exists. Removing..."
        rm -rf "${GEOMAXIMA_PATH}"
    fi
    
    # Clone GeoMaxima repository
    log_info "Cloning GeoMaxima repository..."
    sudo -u "${RTKBASE_USER}" git clone --branch "${GEOMAXIMA_BRANCH}" "${GEOMAXIMA_REPO}" geomaxima
    
    if [ $? -ne 0 ]; then
        log_error "Failed to clone GeoMaxima repository"
        exit 1
    fi
    
    cd "${GEOMAXIMA_PATH}"
    
    # Set proper permissions
    log_info "Setting permissions..."
    chown -R "${RTKBASE_USER}:${RTKBASE_USER}" "${GEOMAXIMA_PATH}"
    chmod +x geomaxima_update.sh
    
    # Install Python dependencies if any
    if [ -f "requirements-geomaxima.txt" ]; then
        log_info "Installing Python dependencies..."
        pip3 install -r requirements-geomaxima.txt --extra-index-url https://www.piwheels.org/simple
    fi
    
    log_info "GeoMaxima installation completed successfully"
}

# Integrate GeoMaxima with RTKBase
integrate_geomaxima() {
    log_step "Integrating GeoMaxima with RTKBase..."
    
    # Check if server.py needs modification
    RTKBASE_SERVER="${RTKBASE_PATH}/web_app/server.py"
    
    if ! grep -q "geomaxima" "${RTKBASE_SERVER}"; then
        log_info "Adding GeoMaxima integration to RTKBase server.py..."
        
        # Find the line with "update_std_user(services_list)" and add after it
        sed -i '/update_std_user(services_list)/a\
        \
        # Initialize GeoMaxima extension if available\
        try:\
            sys.path.insert(0, rtkbase_path)\
            from geomaxima.controller import init_geomaxima\
            geomaxima_controller = init_geomaxima(app)\
            print(f"GeoMaxima v{geomaxima_controller.version} loaded successfully")\
        except ImportError:\
            print("GeoMaxima extension not found - skipping")\
        except Exception as e:\
            print(f"GeoMaxima initialization error: {e}")' "${RTKBASE_SERVER}"
        
        log_info "Server.py modified successfully"
    else
        log_info "GeoMaxima integration already present in server.py"
    fi
    
    # Check if base.html needs modification
    RTKBASE_BASE_HTML="${RTKBASE_PATH}/web_app/templates/base.html"
    
    if ! grep -q "GeoMaxima" "${RTKBASE_BASE_HTML}"; then
        log_info "Adding GeoMaxima menu item to base.html..."
        
        # Add GeoMaxima menu item after Logs
        sed -i '/<li class="nav-item">{{ render_nav_item.*logs_page/a\
        <li class="nav-item">{{ render_nav_item('"'"'geomaxima.index'"'"', '"'"'GeoMaxima'"'"', use_li=True) }}</li>' "${RTKBASE_BASE_HTML}"
        
        log_info "Base.html modified successfully"
    else
        log_info "GeoMaxima menu item already present in base.html"
    fi
}

# Restart services
restart_services() {
    log_step "Restarting RTKBase services..."
    
    systemctl restart rtkbase_web.service
    
    sleep 3
    
    if systemctl is-active --quiet rtkbase_web.service; then
        log_info "RTKBase web service restarted successfully"
    else
        log_error "Failed to restart RTKBase web service"
        log_info "Check logs with: sudo journalctl -u rtkbase_web -n 50"
        exit 1
    fi
}

# Display completion message
display_completion() {
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                           ║${NC}"
    echo -e "${GREEN}║     Installation completed successfully!                 ║${NC}"
    echo -e "${GREEN}║                                                           ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Get IP address
    IP_ADDRESS=$(hostname -I | awk '{print $1}')
    
    log_info "RTKBase + GeoMaxima is now ready!"
    echo ""
    log_info "Access your installation:"
    echo -e "  ${BLUE}RTKBase Dashboard:${NC}  http://${IP_ADDRESS}"
    echo -e "  ${BLUE}GeoMaxima Menu:${NC}     http://${IP_ADDRESS}/geomaxima"
    echo -e "  ${BLUE}WireGuard Client:${NC}   http://${IP_ADDRESS}/geomaxima/wireguard"
    echo ""
    log_info "Default credentials:"
    echo -e "  ${BLUE}Username:${NC} admin"
    echo -e "  ${BLUE}Password:${NC} admin"
    echo ""
    log_warn "IMPORTANT: Change the default password in Settings!"
    echo ""
    log_info "Installation directories:"
    echo -e "  ${BLUE}RTKBase:${NC}    ${RTKBASE_PATH}"
    echo -e "  ${BLUE}GeoMaxima:${NC}  ${GEOMAXIMA_PATH}"
    echo ""
    log_info "Useful commands:"
    echo -e "  ${BLUE}Web service status:${NC}  sudo systemctl status rtkbase_web"
    echo -e "  ${BLUE}View logs:${NC}           sudo journalctl -u rtkbase_web -f"
    echo -e "  ${BLUE}Restart service:${NC}     sudo systemctl restart rtkbase_web"
    echo -e "  ${BLUE}Update GeoMaxima:${NC}    sudo ${GEOMAXIMA_PATH}/geomaxima_update.sh"
    echo ""
    log_info "Documentation:"
    echo -e "  ${BLUE}RTKBase:${NC}    https://github.com/Stefal/rtkbase"
    echo -e "  ${BLUE}GeoMaxima:${NC}  ${GEOMAXIMA_PATH}/README.md"
    echo ""
}

# Main installation flow
main() {
    print_banner
    
    log_info "Starting GeoMaxima complete installation..."
    echo ""
    
    # Pre-installation checks
    check_root
    detect_user
    check_requirements
    backup_existing
    
    # Installation steps
    install_rtkbase
    install_geomaxima
    integrate_geomaxima
    restart_services
    
    # Post-installation
    display_completion
    
    log_info "Installation log saved to: /var/log/geomaxima_install.log"
}

# Trap errors
trap 'log_error "Installation failed at line $LINENO. Check /var/log/geomaxima_install.log for details."' ERR

# Run main and log everything
main 2>&1 | tee /var/log/geomaxima_install.log

exit 0
