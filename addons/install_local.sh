#!/usr/bin/env bash

################################################################################
# GeoMaxima Local Installer
# 
# Installs/updates GeoMaxima from git repo or ZIP archive
# Works for both OTA updates and manual installations
#
# Usage:
#   From git repo (OTA Update):
#     cd ~/GeoMaxima
#     sudo bash install_local.sh
#
#   From ZIP archive:
#     unzip GeoMaxima-vX.X.X.zip
#     cd GeoMaxima
#     sudo bash install_local.sh
################################################################################

# Don't exit on error - handle errors gracefully
# set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_step() { echo -e "${BLUE}[→]${NC} $1"; }

print_banner() {
    echo -e "${BLUE}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════╗
║                                                       ║
║         GeoMaxima Installer                          ║
║                                                       ║
║         Git repo sync + RTKBase integration          ║
║                                                       ║
╚═══════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then 
        log_warn "Not running as root - some operations may fail"
        log_info "For best results, run with: sudo bash install_local.sh"
        # Don't exit - continue anyway
    else
        log_info "Running as root ✓"
    fi
}

detect_user() {
    log_step "Detecting user..."
    
    if [ -n "${SUDO_USER}" ]; then
        RTKBASE_USER="${SUDO_USER}"
        log_info "Detected user: ${RTKBASE_USER}"
    elif [ -n "${USER}" ]; then
        RTKBASE_USER="${USER}"
        log_info "Detected user: ${RTKBASE_USER}"
    else
        # Fallback - try to detect from rtkbase directory owner
        if [ -d "/home/"*"/rtkbase" ]; then
            RTKBASE_USER=$(ls -ld /home/*/rtkbase 2>/dev/null | head -1 | awk '{print $3}')
            log_warn "Could not detect user, assuming: ${RTKBASE_USER}"
        else
            log_error "Cannot detect user - please run with sudo"
            exit 1
        fi
    fi
}

find_rtkbase() {
    log_step "Searching for RTKBase installation..."
    
    # Try common locations
    local possible_paths=(
        "/home/${RTKBASE_USER}/rtkbase"
        "${HOME}/rtkbase"
        "$(eval echo ~${RTKBASE_USER})/rtkbase"
    )
    
    # Also check systemd service for WorkingDirectory
    if systemctl cat rtkbase_web.service >/dev/null 2>&1; then
        local service_path=$(systemctl cat rtkbase_web.service | grep -oP 'WorkingDirectory=\K.*' 2>/dev/null)
        [ -n "${service_path}" ] && possible_paths+=("${service_path}")
    fi
    
    # Check /etc/environment for rtkbase_path
    if [ -f /etc/environment ]; then
        local env_path=$(grep '^rtkbase_path=' /etc/environment 2>/dev/null | cut -d= -f2)
        [ -n "${env_path}" ] && possible_paths+=("${env_path}")
    fi
    
    # Find first valid path
    for path in "${possible_paths[@]}"; do
        if [ -d "${path}" ] && [ -f "${path}/web_app/server.py" ]; then
            RTKBASE_PATH="${path}"
            GEOMAXIMA_PATH="${RTKBASE_PATH}/geomaxima"
            log_info "✅ Found RTKBase at ${RTKBASE_PATH}"
            return 0
        fi
    done
    
    # Not found - offer to install
    log_warn "RTKBase not found in any standard location"
    echo ""
    log_info "Searched locations:"
    for path in "${possible_paths[@]}"; do
        log_info "  - ${path}"
    done
    
    offer_rtkbase_install
    return 0
}

check_rtkbase() {
    find_rtkbase
    
    # Verify it's a complete installation
    if [ ! -f "${RTKBASE_PATH}/settings.conf" ]; then
        log_warn "settings.conf not found - RTKBase may not be fully configured"
    fi
    
    # Check web service
    if systemctl list-unit-files | grep -q "rtkbase_web.service"; then
        log_info "RTKBase web service found"
    else
        log_warn "RTKBase web service not installed"
    fi
}

offer_rtkbase_install() {
    echo ""
    log_warn "RTKBase is not installed on this system"
    log_info "Installing RTKBase automatically..."
    echo ""
    install_rtkbase_now
}

install_rtkbase_now() {
    log_step "Installing RTKBase..."
    
    # Save current directory (where GeoMaxima is)
    local original_dir=$(pwd)
    
    local install_dir="/home/${RTKBASE_USER}"
    cd "${install_dir}"
    
    # Download install script
    log_info "Downloading RTKBase installer..."
    sudo -u "${RTKBASE_USER}" wget -q https://raw.githubusercontent.com/Stefal/rtkbase/master/tools/install.sh -O install_rtkbase.sh
    
    # Make executable
    chmod +x "${install_dir}/install_rtkbase.sh"
    
    # Install RTKBase (needs sudo, script already has it)
    log_info "Installing RTKBase (this will take several minutes)..."
    echo ""
    bash "${install_dir}/install_rtkbase.sh" --all release
    
    # Return to original directory
    cd "${original_dir}"
    
    # Set paths
    RTKBASE_PATH="/home/${RTKBASE_USER}/rtkbase"
    GEOMAXIMA_PATH="${RTKBASE_PATH}/geomaxima"
    
    if [ -d "${RTKBASE_PATH}" ] && [ -f "${RTKBASE_PATH}/web_app/server.py" ]; then
        log_info "✅ RTKBase installed successfully"
        echo ""
    else
        log_error "RTKBase installation failed"
        exit 1
    fi
}

detect_source() {
    log_step "Detecting source files..."
    
    # Get the directory where this script is located
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    
    # Check if we're in the GeoMaxima directory
    if [ ! -f "${SCRIPT_DIR}/VERSION" ]; then
        log_error "Cannot find GeoMaxima files"
        log_error "Make sure you're running from the extracted GeoMaxima folder"
        exit 1
    fi
    
    SOURCE_DIR="${SCRIPT_DIR}"
    VERSION=$(cat "${SOURCE_DIR}/VERSION")
    
    log_info "Found GeoMaxima v${VERSION} at ${SOURCE_DIR}"
}

backup_existing() {
    if [ -d "${GEOMAXIMA_PATH}" ]; then
        BACKUP="${GEOMAXIMA_PATH}.backup.$(date +%Y%m%d_%H%M%S)"
        log_warn "Backing up existing GeoMaxima to ${BACKUP}"
        mv "${GEOMAXIMA_PATH}" "${BACKUP}"
    fi
}

install_dependencies() {
    log_step "Installing dependencies..."
    
    # Check if RTKBase uses virtualenv
    local VENV_PATH="${RTKBASE_PATH}/venv"
    local VENV_PYTHON="${VENV_PATH}/bin/python"
    local VENV_PIP="${VENV_PATH}/bin/pip"
    
    if [ -f "${VENV_PYTHON}" ]; then
        log_info "RTKBase uses virtualenv - installing to venv"
        
        # Check if numpy and scipy are installed in venv
        if ! ${VENV_PYTHON} -c "import numpy" 2>/dev/null; then
            log_info "Installing numpy in virtualenv..."
            sudo -u "${RTKBASE_USER}" ${VENV_PIP} install numpy
        else
            log_info "numpy already installed in venv"
        fi
        
        if ! ${VENV_PYTHON} -c "import scipy" 2>/dev/null; then
            log_info "Installing scipy in virtualenv..."
            sudo -u "${RTKBASE_USER}" ${VENV_PIP} install scipy
        else
            log_info "scipy already installed in venv"
        fi
        
        # Verify installation
        if ${VENV_PYTHON} -c "import numpy, scipy" 2>/dev/null; then
            log_info "✅ Dependencies installed in virtualenv"
            
            # Show versions
            local numpy_ver=$(${VENV_PYTHON} -c "import numpy; print(numpy.__version__)" 2>/dev/null)
            local scipy_ver=$(${VENV_PYTHON} -c "import scipy; print(scipy.__version__)" 2>/dev/null)
            log_info "  NumPy: ${numpy_ver}"
            log_info "  SciPy: ${scipy_ver}"
        else
            log_error "Failed to install dependencies in virtualenv"
            exit 1
        fi
    else
        # Fallback to system packages
        log_info "No virtualenv found - installing system packages"
        
        # Update package list
        log_info "Updating package list..."
        apt-get update -qq
        
        # Check if numpy and scipy are installed
        if ! python3 -c "import numpy" 2>/dev/null; then
            log_info "Installing python3-numpy..."
            apt-get install -y python3-numpy
        else
            log_info "python3-numpy already installed"
        fi
        
        if ! python3 -c "import scipy" 2>/dev/null; then
            log_info "Installing python3-scipy..."
            apt-get install -y python3-scipy
        else
            log_info "python3-scipy already installed"
        fi
        
        # Verify installation
        if python3 -c "import numpy, scipy" 2>/dev/null; then
            log_info "✅ Dependencies installed successfully"
            
            # Show versions
            local numpy_ver=$(python3 -c "import numpy; print(numpy.__version__)" 2>/dev/null)
            local scipy_ver=$(python3 -c "import scipy; print(scipy.__version__)" 2>/dev/null)
            log_info "  NumPy: ${numpy_ver}"
            log_info "  SciPy: ${scipy_ver}"
        else
            log_error "Failed to install dependencies"
            exit 1
        fi
    fi
}

install_rnx2rtkp() {
    log_step "Checking for rnx2rtkp (required for RINEX processing)..."
    
    # Check if rnx2rtkp is already available
    if command -v rnx2rtkp &> /dev/null; then
        local rnx2rtkp_path=$(command -v rnx2rtkp)
        log_info "rnx2rtkp already installed at ${rnx2rtkp_path}"
        return 0
    fi
    
    # Check in /usr/local/bin
    if [ -f "/usr/local/bin/rnx2rtkp" ]; then
        log_info "rnx2rtkp found at /usr/local/bin/rnx2rtkp"
        return 0
    fi
    
    log_warn "rnx2rtkp not found - compiling from RTKLIB..."
    
    # Install build dependencies if not present
    log_info "Installing build dependencies..."
    apt-get update -qq
    
    local deps_needed=0
    if ! dpkg -l | grep -q "^ii  build-essential"; then
        deps_needed=1
    fi
    if ! dpkg -l | grep -q "^ii  gfortran"; then
        deps_needed=1
    fi
    
    if [ $deps_needed -eq 1 ]; then
        log_info "Installing build-essential and gfortran..."
        apt-get install -y build-essential gfortran libgfortran5 || {
            log_error "Failed to install build dependencies"
            return 1
        }
    else
        log_info "Build dependencies already installed"
    fi
    
    # Create temporary directory
    local TMPDIR=$(mktemp -d -t rnx2rtkp.XXXXX)
    local RTKLIB_VERSION="2.5.0"
    
    log_info "Downloading RTKLIB ${RTKLIB_VERSION}..."
    if ! wget -q -O "${TMPDIR}/rtklib.tar.gz" "https://github.com/rtklibexplorer/RTKLIB/archive/refs/tags/v${RTKLIB_VERSION}.tar.gz"; then
        log_error "Failed to download RTKLIB"
        rm -rf "${TMPDIR}"
        return 1
    fi
    
    log_info "Extracting RTKLIB..."
    tar -xzf "${TMPDIR}/rtklib.tar.gz" -C "${TMPDIR}"
    
    log_info "Compiling rnx2rtkp..."
    local RTKLIB_DIR="${TMPDIR}/RTKLIB-${RTKLIB_VERSION}"
    local MAKE_DIR="${RTKLIB_DIR}/app/consapp/rnx2rtkp/gcc"
    
    # Check if makefile exists
    if [ ! -f "${MAKE_DIR}/makefile" ]; then
        log_error "Makefile not found at ${MAKE_DIR}/makefile"
        log_info "Directory contents:"
        ls -la "${MAKE_DIR}" 2>/dev/null || log_error "Directory doesn't exist"
        rm -rf "${TMPDIR}"
        return 1
    fi
    
    # Try to compile with verbose output
    log_info "Running make (this may take a minute)..."
    if make -C "${MAKE_DIR}" 2>&1 | tee /tmp/rnx2rtkp_build.log | tail -5; then
        log_info "Compilation succeeded"
    else
        log_error "Compilation failed. Last 10 lines of build log:"
        tail -10 /tmp/rnx2rtkp_build.log
    fi
    
    # Check if binary was created
    local BINARY="${MAKE_DIR}/rnx2rtkp"
    if [ -f "${BINARY}" ]; then
        log_info "Found compiled binary at ${BINARY}"
        log_info "Installing to /usr/local/bin..."
        cp "${BINARY}" /usr/local/bin/rnx2rtkp
        chmod +x /usr/local/bin/rnx2rtkp
        
        if [ -f "/usr/local/bin/rnx2rtkp" ]; then
            log_info "✅ rnx2rtkp installed successfully"
            /usr/local/bin/rnx2rtkp 2>&1 | head -1 || true
        else
            log_error "Failed to copy binary to /usr/local/bin"
            rm -rf "${TMPDIR}"
            return 1
        fi
    else
        log_error "Binary not found after compilation attempt"
        log_error "Expected at: ${BINARY}"
        rm -rf "${TMPDIR}"
        return 1
    fi
    
    # Cleanup
    rm -rf "${TMPDIR}"
    log_info "Cleaned up temporary files"
}

install_geomaxima() {
    log_step "Installing GeoMaxima..."
    
    # Copy main files to RTKBase/geomaxima
    log_info "Copying core files to ${GEOMAXIMA_PATH}..."
    mkdir -p "${GEOMAXIMA_PATH}"
    
    # Force copy all files except templates and static (they go to web_app)
    # Use rsync for better handling, fallback to cp
    if command -v rsync &> /dev/null; then
        rsync -av --delete --exclude='templates' --exclude='static' --exclude='.git*' \
              --exclude='*.md' --exclude='install_local.sh' \
              "${SOURCE_DIR}/" "${GEOMAXIMA_PATH}/"
    else
        # Fallback to cp with force
        cp -rf "${SOURCE_DIR}"/* "${GEOMAXIMA_PATH}/" 2>/dev/null || true
        rm -rf "${GEOMAXIMA_PATH}/templates" "${GEOMAXIMA_PATH}/static" 2>/dev/null || true
    fi
    
    # Ensure ownership
    chown -R "${RTKBASE_USER}:${RTKBASE_USER}" "${GEOMAXIMA_PATH}"
    
    log_info "Installed features:"
    ls -1 "${GEOMAXIMA_PATH}/features/" 2>/dev/null | grep -v "__" | sed 's/^/  - /' || true
    
    # Copy templates to web_app/templates/geomaxima/
    if [ -d "${SOURCE_DIR}/templates" ]; then
        log_info "Copying templates to web_app..."
        mkdir -p "${RTKBASE_PATH}/web_app/templates/geomaxima"
        
        # If templates has a geomaxima subdirectory, copy its contents
        if [ -d "${SOURCE_DIR}/templates/geomaxima" ]; then
            cp -rf "${SOURCE_DIR}/templates/geomaxima"/* "${RTKBASE_PATH}/web_app/templates/geomaxima/"
        else
            # Otherwise copy all templates
            cp -rf "${SOURCE_DIR}/templates"/* "${RTKBASE_PATH}/web_app/templates/geomaxima/"
        fi
        
        chown -R "${RTKBASE_USER}:${RTKBASE_USER}" "${RTKBASE_PATH}/web_app/templates/geomaxima"
        
        # Show copied templates for verification
        log_info "Templates installed:"
        ls -lh "${RTKBASE_PATH}/web_app/templates/geomaxima/" | tail -n +2 | awk '{printf "  - %s (%s)\n", $9, $5}'
    fi
    
    # Copy static files to web_app/static/geomaxima/
    if [ -d "${SOURCE_DIR}/static" ]; then
        log_info "Copying static files to web_app..."
        mkdir -p "${RTKBASE_PATH}/web_app/static/geomaxima"
        
        # If static has a geomaxima subdirectory, copy its contents
        if [ -d "${SOURCE_DIR}/static/geomaxima" ]; then
            cp -r "${SOURCE_DIR}/static/geomaxima"/* "${RTKBASE_PATH}/web_app/static/geomaxima/"
        else
            # Otherwise copy all static files
            cp -r "${SOURCE_DIR}/static"/* "${RTKBASE_PATH}/web_app/static/geomaxima/"
        fi
    fi
    
    # Also copy templates to geomaxima/templates for reference
    if [ -d "${SOURCE_DIR}/templates" ]; then
        mkdir -p "${GEOMAXIMA_PATH}/templates"
        cp -r "${SOURCE_DIR}/templates"/* "${GEOMAXIMA_PATH}/templates/"
    fi
    
    # Set permissions
    chown -R "${RTKBASE_USER}:${RTKBASE_USER}" "${GEOMAXIMA_PATH}"
    chown -R "${RTKBASE_USER}:${RTKBASE_USER}" "${RTKBASE_PATH}/web_app/templates/geomaxima" 2>/dev/null || true
    chown -R "${RTKBASE_USER}:${RTKBASE_USER}" "${RTKBASE_PATH}/web_app/static/geomaxima" 2>/dev/null || true
    
    # Make all shell scripts executable
    log_info "Setting executable permissions for scripts..."
    find "${GEOMAXIMA_PATH}" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
    
    # Inject RTCM dropdown into RTKBase settings.html
    log_info "Injecting RTCM dropdown into RTKBase settings..."
    if [ -f "${GEOMAXIMA_PATH}/tools/inject_rtcm_dropdown.sh" ]; then
        bash "${GEOMAXIMA_PATH}/tools/inject_rtcm_dropdown.sh" 2>&1 || true
        log_info "RTCM dropdown injection attempted"
    else
        log_info "RTCM dropdown injection script not found (skipping)"
    fi
    
    log_info "✅ GeoMaxima files installed"
}

integrate_geomaxima() {
    log_step "Integrating with RTKBase..."
    
    local SERVER="${RTKBASE_PATH}/web_app/server.py"
    local BASE_HTML="${RTKBASE_PATH}/web_app/templates/base.html"
    
    # Apply hostname patch if available
    if [ -f "${SOURCE_DIR}/patches/rtkbase_hostname.patch" ]; then
        log_info "Checking hostname display patch..."
        
        # Check both parts of the patch
        local server_patched=false
        local base_html_patched=false
        
        # Check if server.py has hostname code
        if grep -q "g.hostname = socket.gethostname()" "${SERVER}"; then
            server_patched=true
        fi
        
        # Check if base.html has hostname in title
        if grep -q "{{ g.hostname }}" "${BASE_HTML}"; then
            base_html_patched=true
        fi
        
        # Apply patch only if needed
        if [ "$server_patched" = true ] && [ "$base_html_patched" = true ]; then
            log_info "✓ Hostname patch already fully applied"
        else
            cd "${RTKBASE_PATH}" || exit 1
            
            # Try to apply patch
            if patch -p1 --dry-run < "${SOURCE_DIR}/patches/rtkbase_hostname.patch" &>/dev/null; then
                # Patch can be applied cleanly
                patch -p1 < "${SOURCE_DIR}/patches/rtkbase_hostname.patch" &>/dev/null
                log_info "✓ Hostname patch applied successfully"
            else
                # Patch fails - apply manually if needed
                if [ "$server_patched" = false ]; then
                    log_info "Manually adding hostname to server.py..."
                    # Find inject_global_infos function and add hostname
                    if grep -q "def inject_global_infos():" "${SERVER}"; then
                        # Add import socket at the top if not present
                        if ! grep -q "^import socket" "${SERVER}"; then
                            sed -i '1i import socket' "${SERVER}"
                        fi
                        # Add g.hostname after g.station_name if not present
                        if ! grep -q "g.hostname = socket.gethostname()" "${SERVER}"; then
                            sed -i '/g.station_name = /a\    g.hostname = socket.gethostname()' "${SERVER}"
                        fi
                        log_info "✓ Hostname added to server.py"
                    else
                        log_warn "Could not find inject_global_infos() in server.py"
                    fi
                fi
                
                if [ "$base_html_patched" = false ]; then
                    log_info "Manually updating base.html title..."
                    # Replace station_name with hostname in title
                    if grep -q "{{ g.station_name }} - RTKBase" "${BASE_HTML}"; then
                        sed -i 's/{{ g.station_name }} - RTKBase/{{ g.hostname }} - RTKBase/g' "${BASE_HTML}"
                        log_info "✓ Title updated in base.html"
                    else
                        log_warn "Could not find title pattern in base.html"
                    fi
                fi
            fi
            
            cd - > /dev/null
        fi
    fi
    
    # Check if already integrated
    if grep -q "init_geomaxima" "${SERVER}"; then
        log_info "GeoMaxima already integrated in server.py"
    else
        log_info "Integrating GeoMaxima into server.py..."
        
        # Find the line with "update_std_user(services_list)" and add GeoMaxima init after it
        # This places it before "manager_thread.start()"
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
        
        log_info "✅ GeoMaxima integrated into server.py"
    fi
    
    # Modify base.html (menu only, title is handled by patch)
    if ! grep -q "GeoMaxima" "${BASE_HTML}"; then
        log_info "Adding GeoMaxima menu..."
        sed -i '/<li class="nav-item">{{ render_nav_item.*logs_page/a\
        <li class="nav-item">{{ render_nav_item('"'"'geomaxima.index'"'"', '"'"'GeoMaxima'"'"', use_li=True) }}</li>' "${BASE_HTML}"
    else
        log_info "GeoMaxima menu already present"
    fi
    
    log_info "✅ Integration complete"
}

initialize_git_repo_for_ota() {
    log_step "Preparing Git repository for OTA updates..."
    if command -v git >/dev/null 2>&1; then
        if [ ! -d "${GEOMAXIMA_PATH}/.git" ]; then
            log_info "Initializing git in deployed GeoMaxima directory"
            sudo -u "${RTKBASE_USER}" git -C "${GEOMAXIMA_PATH}" init 2>/dev/null || true
            sudo -u "${RTKBASE_USER}" git -C "${GEOMAXIMA_PATH}" remote add origin https://github.com/peshovp/GeoMaxima-BS.git 2>/dev/null || true
            sudo -u "${RTKBASE_USER}" git -C "${GEOMAXIMA_PATH}" branch -M master 2>/dev/null || true
            log_info "✓ Git initialized; OTA will fetch from origin when internet is available"
        else
            log_info "✓ Git repository already present at ${GEOMAXIMA_PATH}"
        fi
    else
        log_warn "git not installed; OTA updates require git to fetch from the repository"
    fi

    # Create token placeholder so UI can save it immediately
    if [ ! -f "${GEOMAXIMA_PATH}/.github_token" ]; then
        touch "${GEOMAXIMA_PATH}/.github_token" 2>/dev/null || true
        chmod 600 "${GEOMAXIMA_PATH}/.github_token" 2>/dev/null || true
        chown "${RTKBASE_USER}:${RTKBASE_USER}" "${GEOMAXIMA_PATH}/.github_token" 2>/dev/null || true
        log_info "Created GitHub token placeholder at ${GEOMAXIMA_PATH}/.github_token"
        log_info "Configure token in Web UI: /geomaxima/update → GitHub Access Token"
    fi
}

configure_file_logging() {
    log_step "Configuring RTKBase file logging for Auto Survey..."
    
    # Create state directory
    log_info "Creating state directory..."
    mkdir -p /var/lib/rtkbase
    chown "${RTKBASE_USER}:${RTKBASE_USER}" /var/lib/rtkbase
    
    # Create work directory for survey
    log_info "Creating survey work directory..."
    mkdir -p "${RTKBASE_PATH}/geomaxima_survey"
    chown "${RTKBASE_USER}:${RTKBASE_USER}" "${RTKBASE_PATH}/geomaxima_survey"
    
    # Check if file logging service exists
    if systemctl list-unit-files | grep -q "str2str_file.service"; then
        # Enable service for boot (but don't start it now)
        log_info "Enabling file logging service (for auto-start capability)..."
        systemctl enable str2str_file.service 2>/dev/null || true
        
        # IMPORTANT: Do NOT start service automatically
        # It should only start when:
        # 1. User starts Auto Survey
        # 2. User manually clicks "Start Logging" in UI
        # 3. User runs: curl -X POST http://localhost/geomaxima/api/survey/logging/start
        
        if systemctl is-active --quiet str2str_file.service; then
            log_warn "File logging is currently RUNNING - it will consume disk space!"
            log_info "To stop it: sudo systemctl stop str2str_file.service"
            log_info "Or use Manual Controls in Auto Survey UI"
        else
            log_info "✓ File logging is STOPPED (will auto-start on survey)"
        fi
    else
        log_warn "str2str_file.service not found - Auto Survey will try to start it automatically"
    fi
    
    log_info "✅ File logging configured"
}

configure_ota_permissions() {
    log_step "Configuring OTA Update permissions..."
    
    # Create sudoers file for OTA Update feature
    local SUDOERS_FILE="/etc/sudoers.d/geomaxima-ota"
    
    log_info "Setting up passwordless sudo for OTA operations..."
    
    cat > "${SUDOERS_FILE}" << EOF
# GeoMaxima OTA Update - Passwordless sudo for web-based updates
# Created: $(date)
# User: ${RTKBASE_USER}

# Allow restart of rtkbase_web service (needed after update)
${RTKBASE_USER} ALL=(ALL) NOPASSWD: /bin/systemctl restart rtkbase_web
${RTKBASE_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart rtkbase_web

# Allow restart of RTKBase str2str services (needed after Auto Survey)
${RTKBASE_USER} ALL=(ALL) NOPASSWD: /bin/systemctl restart str2str_tcp.service
${RTKBASE_USER} ALL=(ALL) NOPASSWD: /bin/systemctl restart str2str_ntrip_A.service
${RTKBASE_USER} ALL=(ALL) NOPASSWD: /bin/systemctl restart str2str_ntrip_B.service
${RTKBASE_USER} ALL=(ALL) NOPASSWD: /bin/systemctl restart str2str_rtcm_svr.service
${RTKBASE_USER} ALL=(ALL) NOPASSWD: /bin/systemctl restart str2str_rtcm_serial.service
${RTKBASE_USER} ALL=(ALL) NOPASSWD: /bin/systemctl restart str2str_local_ntrip_caster.service
${RTKBASE_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart str2str_tcp.service
${RTKBASE_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart str2str_ntrip_A.service
${RTKBASE_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart str2str_ntrip_B.service
${RTKBASE_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart str2str_rtcm_svr.service
${RTKBASE_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart str2str_rtcm_serial.service
${RTKBASE_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart str2str_local_ntrip_caster.service

# Allow running install script (needed for update process)
${RTKBASE_USER} ALL=(ALL) NOPASSWD: /bin/bash ${GEOMAXIMA_PATH}/install_local.sh
${RTKBASE_USER} ALL=(ALL) NOPASSWD: ${GEOMAXIMA_PATH}/install_local.sh

# Security: These are the ONLY commands allowed without password
# Do NOT add wildcards or broad permissions
EOF

    # Set correct permissions (sudoers files MUST be 0440)
    chmod 0440 "${SUDOERS_FILE}"
    
    # Validate sudoers syntax
    if visudo -c -f "${SUDOERS_FILE}" &>/dev/null; then
        log_info "✓ Sudoers configuration valid"
    else
        log_error "Sudoers syntax error - removing file for safety"
        rm -f "${SUDOERS_FILE}"
        log_warn "OTA Update will require password prompts"
        return 1
    fi
    
    log_info "✅ OTA Update permissions configured"
    log_info "   User '${RTKBASE_USER}' can now:"
    log_info "   - Restart rtkbase_web service"
    log_info "   - Run install_local.sh script"
    log_info "   - Perform web-based updates without SSH"
}

restart_services() {
    log_step "Restarting services..."
    
    # Clear Python cache before restart
    log_info "Clearing Python cache..."
    find "${RTKBASE_PATH}" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
    find "${RTKBASE_PATH}" -name "*.pyc" -delete 2>/dev/null || true
    
    systemctl restart rtkbase_web.service 2>/dev/null || true
    sleep 3
    
    if systemctl is-active --quiet rtkbase_web.service; then
        log_info "✅ Service started successfully"
    else
        log_warn "Service may not have started - check logs"
    fi
}

display_completion() {
    local IP=$(hostname -I | awk '{print $1}')
    local INSTALLED_VERSION=$(cat "${GEOMAXIMA_PATH}/VERSION" 2>/dev/null || echo "unknown")
    
    echo ""
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║                                                       ║"
    echo "║            ✅ Installation Complete!                 ║"
    echo "║                                                       ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    log_info "📦 GeoMaxima v${INSTALLED_VERSION} installed successfully"
    echo ""
    log_info "⚡ Access GeoMaxima:"
    log_info "   Dashboard:    http://${IP}/geomaxima"
    log_info "   WireGuard:    http://${IP}/geomaxima/wireguard"
    log_info "   Auto Survey:  http://${IP}/geomaxima/survey"
    log_info "   OTA Update:   http://${IP}/geomaxima/update"
    echo ""
    log_info "🔄 Update to latest version:"
    log_info "   METHOD 1 (Web UI - Recommended):"
    log_info "     → Open: http://${IP}/geomaxima/update"
    log_info "     → Click 'Check for Updates'"
    log_info "     → Click 'Install Update'"
    log_info "   METHOD 2 (SSH/Terminal):"
    log_info "   cd ~/GeoMaxima"
    log_info "   git pull origin master"
    log_info "   sudo ./install_local.sh"
    echo ""
    log_info "🔍 Check Status:"
    log_info "   sudo systemctl status rtkbase_web"
    log_info "   sudo journalctl -u rtkbase_web -n 50"
    echo ""
    log_info "📂 Installed files:"
    log_info "   Python:    ${GEOMAXIMA_PATH}"
    log_info "   Templates: ${RTKBASE_PATH}/web_app/templates/geomaxima"
    log_info "   Work dir:  ${RTKBASE_PATH}/geomaxima_survey"
    echo ""
}

# Main installation flow
main() {
    print_banner
    
    check_root
    detect_user
    check_rtkbase
    detect_source
    backup_existing
    install_dependencies
    install_rnx2rtkp
    install_geomaxima
    integrate_geomaxima
    initialize_git_repo_for_ota
    configure_file_logging
    configure_ota_permissions
    restart_services
    display_completion
}

# Run
main "$@"
