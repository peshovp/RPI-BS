#!/usr/bin/env bash
# =============================================================================
# tools/security_setup.sh - Security hardening for RTKBase/Raspberry Pi OS
# =============================================================================
# Idempotent security setup script with logging functions
# SSH access MUST be configured BEFORE enabling UFW
# =============================================================================

set -euo pipefail

# Logging functions
log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a /var/log/security_setup.log 2>/dev/null || echo "[INFO] $1"
}

log_warn() {
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a /var/log/security_setup.log 2>/dev/null || echo "[WARN] $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a /var/log/security_setup.log 2>/dev/null || echo "[ERROR] $1" >&2
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root"
    exit 1
fi

log_info "Starting security hardening..."

# =============================================================================
# Step 1: Update system packages
# =============================================================================
log_info "Updating package lists and upgrading system..."
apt update -qq
apt full-upgrade -y -qq
log_info "System packages updated successfully"

# =============================================================================
# Step 2: Install UFW firewall
# =============================================================================
log_info "Installing UFW firewall..."
if ! command -v ufw &>/dev/null; then
    apt install -y -qq ufw
    log_info "UFW installed successfully"
else
    log_info "UFW already installed, skipping installation"
fi

# =============================================================================
# Step 3: Configure SSH access BEFORE enabling UFW (CRITICAL!)
# =============================================================================
log_info "Configuring firewall rules for SSH access..."

# Allow SSH on port 22 (or custom port if configured)
SSH_PORT="${SSH_PORT:-22}"
ufw allow "${SSH_PORT}/tcp" || {
    log_error "Failed to allow SSH port ${SSH_PORT}"
    exit 1
}

log_info "SSH access allowed on port ${SSH_PORT}"

# =============================================================================
# Step 4: Interactively enable UFW with confirmation
# =============================================================================
log_info "UFW configured. Enabling firewall (requires confirmation)..."

echo ""
echo "============================================================================"
echo "  SECURITY WARNING: The following changes will be applied:"
echo "    - UFW firewall will be ENABLED"
echo "    - SSH access on port ${SSH_PORT} is ALLOWED"
echo "    - All other incoming traffic will be BLOCKED by default"
echo ""
echo "  This is a CRITICAL security measure for your Raspberry Pi."
echo "============================================================================"
echo ""

read -rp "Enable UFW firewall? [y/N]: " enable_ufw
if [[ "${enable_ufw,,}" != "y" && "${enable_ufw,,}" != "yes" ]]; then
    log_info "UFW enabled manually later (user declined auto-enable)"
    ufw --force disable
    echo ""
    echo "============================================================================"
    echo "  UFW is DISABLED. Please enable it manually when ready:"
    echo "    sudo ufw enable"
    echo "============================================================================"
    exit 0
fi

log_info "Enabling UFW firewall..."
ufw --force enable || {
    log_error "Failed to enable UFW"
    exit 1
}
log_info "UFW enabled successfully"

# =============================================================================
# Step 5: Install and configure fail2ban
# =============================================================================
log_info "Installing fail2ban..."
if ! command -v fail2ban &>/dev/null; then
    apt install -y -qq fail2ban
    log_info "fail2ban installed successfully"
else
    log_info "fail2ban already installed, skipping installation"
fi

# Create jail.local with SSH protection
log_info "Configuring fail2ban for SSH protection..."
JAIL_LOCAL="/etc/fail2ban/jail.local"

cat > "${JAIL_LOCAL}" << EOF
[DEFAULT]
# Ban after 5 attempts
maxretry = 5
# Ban duration: 1 hour
bantime = 3600
# Find time window: 10 minutes
findtime = 600
# Ignore IPs from localhost and common networks
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
findtime = 600
EOF

# Ensure jail.local has correct permissions
chmod 640 "${JAIL_LOCAL}"
chown root:root "${JAIL_LOCAL}"

log_info "fail2ban jail.local configured for SSH protection"

# Restart fail2ban to apply new configuration immediately
if command -v systemctl &>/dev/null; then
    systemctl restart fail2ban || {
        log_warn "Failed to restart fail2ban service"
    }
fi

log_info "Security hardening completed successfully!"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "============================================================================"
echo "  SECURITY SETUP COMPLETED SUCCESSFULLY"
echo "============================================================================"
echo ""
echo "Applied security measures:"
echo "  ✓ System packages updated (apt full-upgrade)"
echo "  ✓ UFW firewall installed and ENABLED"
echo "  ✓ SSH access allowed on port ${SSH_PORT}"
echo "  ✓ fail2ban configured with jail.local (maxretry=5, bantime=1h)"
echo ""

# Verify status immediately
systemctl status fail2ban --no-pager || true
ufw status verbose

echo ""
echo "============================================================================"
echo "IMPORTANT: Never change SSH port without updating this script's SSH_PORT variable!"
echo "============================================================================"

exit 0