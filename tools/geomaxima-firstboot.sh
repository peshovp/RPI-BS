#!/usr/bin/env bash
# =============================================================================
#  tools/geomaxima-firstboot.sh
#  Run by geomaxima-firstboot.service (a systemd oneshot unit written
#  directly into the eMMC target by install.sh's Plan B SD->eMMC migration
#  flow - see the "A733: unattended SD-to-eMMC migration" section of
#  install.sh). This is PHASE 2: it runs install.sh itself (with
#  GM_PHASE=2, read from /etc/geomaxima/install.env) once the board has
#  booted from eMMC.
#
#  GeoMaxima: committed as a real, shellcheck-able file rather than
#  generated via heredoc into the git checkout - a heredoc-written copy
#  would leave the checkout with an untracked/dirty file that could
#  conflict with (or block) a future `git pull --ff-only`.
#
#  Retries: caps at 3 attempts via a counter file. Disables itself
#  (systemctl disable) on eventual SUCCESS, or after the 3rd failed
#  attempt - never loops indefinitely across reboots. Waits for basic
#  network reachability before attempting install.sh, since a fresh eMMC
#  boot can reach this unit (After=network-online.target/Wants=) before
#  DNS is actually usable in practice on some setups.
# =============================================================================

set -uo pipefail

ENV_FILE="/etc/geomaxima/install.env"
LOG_FILE="/var/log/geomaxima-install.log"
COUNTER_FILE="/etc/geomaxima/firstboot-attempts"
UNIT_NAME="geomaxima-firstboot.service"
MAX_ATTEMPTS=3
NET_WAIT_SECONDS=300

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
INSTALL_DIR="${INSTALL_DIR:-/opt/RPI-BS}"

# GeoMaxima: confirmed live that systemd services run with essentially no
# login-session environment at all - $HOME, $USER, $LOGNAME, and $TERM are
# all unset here (this is PHASE 2, launched by
# geomaxima-firstboot.service, not an interactive shell). install.sh (and
# scripts it calls) has at least one spot that assumes $HOME is set
# (tools/install.sh's free-disk-space check, `df "$HOME"` -> `df ""` ->
# "No such file or directory", which made the install exit as if disk
# space were low even with 26.9 GB free) - fixed at that call site too
# (`${HOME:-/}`), but setting a sane environment HERE, once, before
# install.sh even starts, is the belt-and-braces fix: it also covers any
# OTHER script phase 2 runs (tools/security_setup.sh, tools/copy_unit.sh,
# the PRIDE-PPPAR build step, ...) that might assume a normal login
# session's environment, present or future, without needing to audit and
# patch every individual call site as new ones are found.
export HOME="${HOME:-/root}"
export USER="${USER:-root}"
export LOGNAME="${LOGNAME:-root}"
export TERM="${TERM:-dumb}"
export LANG="${LANG:-C.UTF-8}"

attempt=0
[[ -f "$COUNTER_FILE" ]] && attempt="$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)"
attempt=$(( attempt + 1 ))
echo "$attempt" > "$COUNTER_FILE"

{
    echo "=== geomaxima-firstboot attempt $attempt: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

    if [[ "$attempt" -gt "$MAX_ATTEMPTS" ]]; then
        echo "Reached $MAX_ATTEMPTS failed attempts - disabling $UNIT_NAME and giving up."
        echo "Investigate this log, fix the underlying issue, then run install.sh manually:"
        echo "  sudo bash ${INSTALL_DIR}/install.sh"
        systemctl disable "$UNIT_NAME" 2>/dev/null || true
        exit 0
    fi

    # GeoMaxima: wait for real DNS resolution, not just "an interface is
    # up" (network-online.target can be reached before DNS is actually
    # usable on some setups) - install.sh needs github.com (git
    # clone/pull) and several download hosts to work at all.
    echo "Waiting up to ${NET_WAIT_SECONDS}s for network (github.com to resolve)..."
    net_waited=0
    net_ok=0
    while (( net_waited < NET_WAIT_SECONDS )); do
        if getent hosts github.com >/dev/null 2>&1; then
            net_ok=1
            break
        fi
        sleep 5
        net_waited=$(( net_waited + 5 ))
    done
    if [[ "$net_ok" != "1" ]]; then
        echo "Network did not become ready within ${NET_WAIT_SECONDS}s (github.com never resolved) - failing this attempt ($attempt/$MAX_ATTEMPTS)."
        exit 1
    fi
    echo "Network is ready (github.com resolved after ${net_waited}s)."

    bash "${INSTALL_DIR}/install.sh"
    RC=$?
    echo "install.sh exited $RC"
    if [[ "$RC" -eq 0 ]]; then
        echo "Phase 2 install succeeded - disabling $UNIT_NAME."
        systemctl disable "$UNIT_NAME" 2>/dev/null || true
        rm -f "$COUNTER_FILE"

        # GeoMaxima: read web_port from THIS station's actual settings.conf
        # (written by tools/install.sh during the install that just ran),
        # not via `os.getenv` (which would only see a WEB_PORT environment
        # variable, not the configured value) - matches the same
        # `source <(grep '=' settings.conf)` convention used elsewhere in
        # this project (tools/convbin.sh, tools/geomaxima_configure_firewall.sh).
        web_port=80
        if [[ -f "${INSTALL_DIR}/settings.conf" ]]; then
            set +u
            # shellcheck disable=SC1090
            source <(grep '=' "${INSTALL_DIR}/settings.conf")
            set -u
        fi
        web_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
        echo "Install complete: http://${web_ip}:${web_port:-80}" | tee -a /etc/motd >/dev/null || true
    else
        echo "Phase 2 install FAILED (attempt $attempt/$MAX_ATTEMPTS) - will retry on next boot if under the attempt limit."
    fi
    exit "$RC"
} 2>&1 | tee -a "$LOG_FILE"
