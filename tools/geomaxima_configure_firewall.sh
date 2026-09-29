#!/usr/bin/env bash
# =============================================================================
#  tools/geomaxima_configure_firewall.sh
#  Adds UFW rules for this station's ACTUAL service ports (read from
#  settings.conf, once tools/install.sh has created it) and only then
#  enables UFW - and enables it, since fail2ban and SSH-allow already ran
#  in tools/security_setup.sh, but that script runs BEFORE settings.conf
#  exists, so it could not safely enable UFW itself (see its header
#  comment for the full "why").
#
#  Idempotent: `ufw allow` on an already-present rule is a harmless no-op,
#  and `ufw --force enable` on an already-enabled firewall is also a
#  no-op. Safe to re-run (e.g. from a later OTA update after ports change).
#
#  Usage: sudo ./tools/geomaxima_configure_firewall.sh [path/to/settings.conf]
#  (defaults to ./settings.conf relative to the current directory, matching
#  install.sh's own convention of cd'ing into the checkout first)
# =============================================================================

set -euo pipefail

log() { echo "$1" >&2; }

if [[ $EUID -ne 0 ]]; then
    log "ERROR: This script must be run as root (or using sudo)."
    exit 1
fi

if ! command -v ufw &>/dev/null; then
    log "WARNING: ufw is not installed - skipping firewall configuration. Run tools/security_setup.sh first."
    exit 0
fi

SETTINGS_CONF="${1:-settings.conf}"
if [[ ! -f "$SETTINGS_CONF" ]]; then
    log "WARNING: $SETTINGS_CONF not found - skipping firewall configuration (nothing to read ports from yet)."
    exit 0
fi

# GeoMaxima: settings.conf is an INI-style file ([section] headers,
# key=value lines, # comments) - NOT directly shell-sourceable (a raw
# `source` would fail on the "[general]" line as if it were a command).
# `source <( grep '=' file )` is this project's own established convention
# for shell-consuming it, already used by tools/convbin.sh - reused here
# rather than introducing a second, different parsing method.
#
# set +u around this one line: web_password_hash's value contains
# literal "$..." segments (a pbkdf2 hash, e.g.
# "pbkdf2:sha256:150000$kWdEE8eU$...") which get shell-expanded as
# variable references when this file is sourced unquoted - under `set -u`
# (this script's default, unlike convbin.sh which has none) an unset
# variable of that name would abort the whole script. This does not
# affect the port values actually needed below.
set +u
# shellcheck disable=SC1090
source <(grep '=' "$SETTINGS_CONF")
set -u

# SSH: re-detect the same way tools/security_setup.sh did, rather than
# trusting a value that could have changed since (e.g. a manual sshd_config
# edit between STAGE 2 and STAGE 3 of install.sh).
if [[ -n "${SSH_PORT:-}" ]]; then
    : # explicit override, use as-is
elif command -v sshd &>/dev/null; then
    SSH_PORT="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')"
fi
SSH_PORT="${SSH_PORT:-22}"

log "Configuring UFW rules for this station's actual service ports..."

_allow_port() {
    # $1: port, $2: proto (tcp/udp), $3: human-readable label for logging
    local port="$1" proto="$2" label="$3"
    if [[ -z "$port" ]]; then
        return 0
    fi
    if ufw allow "${port}/${proto}" comment "$label" &>/dev/null; then
        log "✓ Allowed ${proto}/${port} ($label)"
    else
        log "WARNING: failed to allow ${proto}/${port} ($label) - continuing."
    fi
}

_allow_port "$SSH_PORT" tcp "SSH"
_allow_port "${web_port:-}" tcp "RTKBase web UI"
_allow_port "${tcp_port:-}" tcp "RTKBase TCP stream (str2str)"
_allow_port "${ext_tcp_port:-}" tcp "RTKBase external TCP source"
_allow_port "${local_ntripc_port:-}" tcp "NTRIP caster"
_allow_port "${rtcm_svr_port:-}" tcp "RTCM server (TCP)"
_allow_port "${rtcm_udp_svr_port:-}" udp "RTCM server (UDP)"

# zeroconf/avahi (mDNS, 5353/udp) is only relevant if tools/install.sh was
# actually run with --zeroconf (install.sh's own default invocation does
# NOT pass it) - gate on whether avahi-daemon is actually active, matching
# this project's existing detect-and-degrade convention, rather than
# opening 5353 unconditionally on stations that never enabled it.
if systemctl is-active --quiet avahi-daemon.service 2>/dev/null; then
    _allow_port 5353 udp "avahi/zeroconf (mDNS)"
fi

# GeoMaxima note: WireGuard on this station is CLIENT-only
# (addons/features/wireguard_client.py - an outbound tunnel to a remote
# server), not a locally-listening service, so there is no local WireGuard
# listen port to open here. If a future feature adds a listening
# WireGuard interface on this station, its port must be added above.

log "Enabling UFW..."
if ufw --force enable; then
    log "✓ UFW enabled."
else
    log "ERROR: failed to enable UFW."
    exit 1
fi

ufw status verbose || true
