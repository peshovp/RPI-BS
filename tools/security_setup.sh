#!/usr/bin/env bash
# =============================================================================
# tools/security_setup.sh - Security hardening for RTKBase/Raspberry Pi OS
# =============================================================================
# Idempotent security setup script with logging functions
# SSH access MUST be configured BEFORE enabling UFW
#
# GeoMaxima: UFW is installed and SSH access is allowed here, but UFW is no
# longer ENABLED by this script. settings.conf (which lists this station's
# actual web/RTCM/NTRIP ports) does not exist yet at this point in the
# install (this script runs BEFORE tools/install.sh, which is what creates
# it) - enabling UFW here, with only SSH allowed, would lock the station's
# own web UI and GNSS data ports out from behind its own firewall the
# moment it comes up. UFW is now installed+SSH-allowed-but-left-disabled
# here, and a separate step later in install.sh (after tools/install.sh has
# written settings.conf) adds rules for every port the station actually
# uses and only then enables it. See geomaxima_configure_firewall.sh.
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

# GeoMaxima: sanity-check DNS right after the first apt operations of this
# script - confirmed live on an Orange Pi 4 Pro+ that a later, unrelated
# apt-get install (openresolv, in install.sh's own STAGE 1) silently
# removed the active systemd-resolved package, breaking DNS with no
# warning; --no-remove (added below to this script's own apt installs) is
# the primary defense against that class of bug, this health check is a
# secondary tripwire specifically for DNS. Script dir resolved via
# BASH_SOURCE since this script is also runnable standalone, not only from
# inside install.sh's already-established $SCRIPT_DIR.
SECURITY_SETUP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$SECURITY_SETUP_SCRIPT_DIR/tools/dns_setup.sh" ]]; then
    # shellcheck source=tools/dns_setup.sh
    source "$SECURITY_SETUP_SCRIPT_DIR/tools/dns_setup.sh"
    if ! geomaxima_dns_health_check; then
        log_error "DNS resolution check failed after 'apt full-upgrade' - see diagnostic output above. Aborting rather than continuing into a cascade of apt/network failures."
        exit 1
    fi
fi

# =============================================================================
# Step 2: Install UFW firewall
# =============================================================================
log_info "Installing UFW firewall..."
if ! command -v ufw &>/dev/null; then
    apt install -y -qq --no-remove ufw
    log_info "UFW installed successfully"
else
    log_info "UFW already installed, skipping installation"
fi

# =============================================================================
# Step 3: Allow SSH access, but do NOT enable UFW yet (see header comment)
# =============================================================================
log_info "Configuring firewall rules for SSH access..."

# GeoMaxima: detect the SSH port from sshd's own effective configuration
# instead of assuming 22 - `sshd -T` prints the fully-resolved config
# (after Include files, Match blocks' unconditional directives, etc.) that
# sshd itself would actually use, which is more reliable than grepping
# sshd_config directly (a custom Port could be set via an Include'd file,
# commented-then-overridden, etc.). Falls back to 22 (and to the
# SSH_PORT env override, for anyone who still wants to force a value) if
# sshd is missing or `-T` fails for any reason.
if [[ -n "${SSH_PORT:-}" ]]; then
    : # explicit override, use as-is
elif command -v sshd &>/dev/null; then
    SSH_PORT="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')"
fi
SSH_PORT="${SSH_PORT:-22}"

ufw allow "${SSH_PORT}/tcp" || {
    log_error "Failed to allow SSH port ${SSH_PORT}"
    exit 1
}

log_info "SSH access allowed on port ${SSH_PORT}"
log_info "UFW installed and SSH-allowed, left DISABLED for now - a later install.sh step enables it once this station's actual service ports are known (see tools/geomaxima_configure_firewall.sh)."

# =============================================================================
# Step 4: Install and configure fail2ban
# =============================================================================
# GeoMaxima: this step must run regardless of the (now-removed) interactive
# UFW-enable decision above - fail2ban protects SSH independently of UFW,
# and previously this whole step was skipped whenever the user declined
# UFW (the old Step 4 did `exit 0` before ever reaching fail2ban). Fixed by
# removing that early exit entirely; fail2ban always runs now.
# =============================================================================
log_info "Installing fail2ban..."
if ! command -v fail2ban &>/dev/null; then
    apt install -y -qq --no-remove fail2ban
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
echo "  ✓ UFW firewall installed, SSH access allowed on port ${SSH_PORT} - NOT YET ENABLED"
echo "  ✓ fail2ban configured with jail.local (maxretry=5, bantime=1h)"
echo ""
echo "UFW will be enabled automatically later in install.sh, once this station's"
echo "actual service ports (web UI, RTCM, NTRIP, ...) are known from settings.conf."
echo ""

# Verify status immediately
systemctl status fail2ban --no-pager || true
ufw status verbose

echo ""
echo "============================================================================"
echo "IMPORTANT: SSH_PORT was auto-detected from sshd's effective config (sshd -T)."
echo "If you change the SSH port later, re-run this script so both UFW and"
echo "fail2ban's jail.local get updated to match."
echo "============================================================================"

exit 0