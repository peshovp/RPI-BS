#!/usr/bin/env bash
# =============================================================================
#  tools/dns_setup.sh
#  Meant to be SOURCED by install.sh and addons/tools/perform_update.sh.
#
#  DNS POLICY (decided by the project owner):
#    - No hard-coded DNS servers anywhere: no public resolver, no public
#      fallback. Each station uses the DNS its own network provides (DHCP
#      from the router it sits behind, or a static setting the user
#      configured on the station itself).
#    - DNS never comes from the WireGuard tunnel: no "DNS =" line in any
#      WireGuard config, so wg-quick never registers a resolver with
#      resolvconf/openresolv and can never put it into exclusive mode.
#    - If the network provides no DNS at all, that is reported as an ERROR
#      (log + UI) - never papered over with a public resolver.
#
#  WHY THIS FILE CHANGED (confirmed live on a test station, 2026-09):
#    1. /etc/wireguard/wg0.conf contained "DNS = 8.8.8.8". wg-quick then ran
#       `resolvconf -a wg0 -m 0 -x`; the -x (exclusive) entry made
#       /etc/resolv.conf contain ONLY "nameserver 8.8.8.8", overriding the
#       NetworkManager list entirely. That config line came from outside
#       this repo - this repo never generates WireGuard configs, only stores
#       what the user pastes/enters (see web_app/wireguard_settings.py,
#       addons/features/wireguard_client.py, which now strip DNS lines).
#    2. This file's own former geomaxima_configure_dns_fallback() added
#       8.8.8.8 and 1.1.1.1 to the active NetworkManager connection
#       (`nmcli connection modify <conn> +ipv4.dns 8.8.8.8 +ipv4.dns
#       1.1.1.1`), ran from install.sh AND on every OTA. On a netplan-
#       managed connection ("netplan-eth0") NetworkManager persists that
#       into /etc/netplan/90-NM-<uuid>.yaml, putting the public resolvers
#       AHEAD of the router's. The same function also wrote public
#       fallbacks for systemd-resolved (FallbackDNS drop-in), openresolv
#       (append_nameservers) and Debian resolvconf (resolv.conf.d/tail).
#    3. That ISP blocks/throttles DNS sent to public resolvers (8.8.8.8
#       answered 1/4, 1.1.1.1 0/4, the router 4/4), so every lookup
#       depended on 8.8.8.8 happening to answer: OTA git fetch, and pdp3's
#       product downloads ("Resolving timed out").
#
#  FUNCTIONS (names kept for compatibility - see note below):
#    geomaxima_maybe_install_openresolv()
#        Now a no-op. openresolv was only ever installed so wg-quick's
#        DNS= could work; WireGuard no longer sets DNS. An already-installed
#        openresolv is left alone (NetworkManager may be using it).
#    geomaxima_configure_dns_fallback()
#        Now runs geomaxima_dns_migrate(): removes every public resolver
#        this project injected and every WireGuard DNS line, with a before/
#        after resolution check and full rollback. Idempotent.
#    geomaxima_dns_health_check [host]
#        Returns 0 if the system resolver works; logs diagnostics otherwise.
#
#  OTA COMPATIBILITY NOTE: stations run their OLD perform_update.sh during
#  the OTA that delivers this file, and that old script sources THIS file
#  (from disk, after `git reset`) and calls the three names above. Keeping
#  the names means the migration runs in the very same OTA that delivers
#  it. Do not rename them.
#
#  Test seams (real runs never set them): GM_ETC (default /etc), GM_RUN
#  (default /run), GM_STATE_DIR (default /var/lib/rtkbase),
#  GM_DNS_SETTLE_SECONDS (default 30).
# =============================================================================

# Hosts the station actually needs: OTA (github.com) and pdp3/PPP product
# mirrors. Used for the before/after check and by the watchdog self-test.
GM_DNS_TEST_HOSTS=(github.com bdspride.com igs.gnsswhu.cn igs.bkg.bund.de)

# The exact pair this project's former fallback step injected. Used ONLY to
# find and REMOVE that injection - never written anywhere. A resolver list
# is treated as ours only when it contains BOTH addresses (the old code
# always added the pair), so a single public resolver a user configured
# deliberately is left alone.
GM_INJECTED_DNS=(8.8.8.8 1.1.1.1)

# glibc resolver options written for openresolv-managed resolv.conf
# (glibc default is timeout:5 attempts:2 - long enough that one dead
# server stalls every lookup).
GM_RESOLV_OPTIONS="timeout:2 attempts:2"

_gm_dns_log()  { echo "[dns] $*"; }
_gm_dns_err()  { echo "[dns] ERROR: $*" >&2; }
_gm_dns_warn() { echo "[dns] WARNING: $*" >&2; }

# _gm_dns_probe <window_seconds>: prints how many of GM_DNS_TEST_HOSTS
# resolve through the system resolver (getent = glibc, the same path
# git/curl/wget use). Hosts that fail are retried every 5 s for the whole
# window; a host counts as resolved if ANY attempt succeeds. One slow
# lookup (the router took 1120 ms for igs.bkg.bund.de, confirmed live)
# must not decide the result. Attempts are counted rather than timed, so a
# stubbed `sleep` in tests stays deterministic.
_gm_dns_probe() {
    local window="${1:-0}" attempt=0 h
    local max_attempts=$(( window / 5 + 1 ))
    local -A resolved=()
    while (( attempt < max_attempts )); do
        attempt=$((attempt + 1))
        for h in "${GM_DNS_TEST_HOSTS[@]}"; do
            [[ -n "${resolved[$h]:-}" ]] && continue
            if timeout 12 getent ahostsv4 "$h" >/dev/null 2>&1; then
                resolved[$h]=1
            fi
        done
        (( ${#resolved[@]} == ${#GM_DNS_TEST_HOSTS[@]} )) && break
        (( attempt < max_attempts )) && sleep 5
    done
    echo "${#resolved[@]}"
}

# _gm_dns_nameservers: nameserver lines currently in resolv.conf.
_gm_dns_nameservers() {
    awk '$1 == "nameserver" {print $2}' "${GM_ETC:-/etc}/resolv.conf" 2>/dev/null
}

# _gm_has_injected_pair <list...>: true if both GM_INJECTED_DNS addresses
# are in the given list.
_gm_has_injected_pair() {
    local list=" $* " a
    for a in "${GM_INJECTED_DNS[@]}"; do
        [[ "$list" == *" $a "* ]] || return 1
    done
    return 0
}

# _gm_wg_up <iface>: true if the interface exists and is up.
_gm_wg_up() {
    ip link show "$1" 2>/dev/null | grep -q 'state UP\|,UP'
}

geomaxima_maybe_install_openresolv() {
    _gm_dns_log "openresolv is not installed by this project any more (WireGuard no longer sets DNS, so wg-quick never needs resolvconf). An existing installation is left as it is."
    return 0
}

# geomaxima_configure_dns_fallback: runs the DNS migration and ALWAYS
# returns 0.
#
# The name is now misleading - it no longer configures any fallback, it
# REMOVES the public fallbacks this project used to add. It is kept
# because stations run their OLD addons/tools/perform_update.sh during the
# OTA that delivers this file, and that old script (under `set -e`, after
# `git reset` has already put this file on disk) calls exactly this name.
# Renaming it would make the delivering OTA skip the migration.
#
# Always 0: this runs half-way through an OTA, before the ANTEX/PRIDE
# steps and the service restart; a non-zero status must never be able to
# stop that. Every failure is logged and recorded in
# /var/lib/rtkbase/dns_migration.json instead. The migration runs in a
# subshell with errexit off, so neither a failing internal command nor a
# caller's `set -e` can cut it short or propagate.
geomaxima_configure_dns_fallback() {
    local rc=0
    ( set +e; geomaxima_dns_migrate ) || rc=$?
    if (( rc != 0 )); then
        _gm_dns_err "DNS migration ended with status $rc - recorded; continuing (never fatal)"
        _gm_dns_report_state "error" "migration ended with status $rc" 2>/dev/null || true
    fi
    return 0
}

# geomaxima_dns_migrate: remove injected public DNS + WireGuard DNS lines,
# verify, roll back if resolution got worse. Safe to run any number of
# times; changes nothing (and restarts nothing) when there is nothing to
# change. Never restarts WireGuard and never bounces the network link.
geomaxima_dns_migrate() {
    local etc="${GM_ETC:-/etc}" run="${GM_RUN:-/run}" state="${GM_STATE_DIR:-/var/lib/rtkbase}"
    local ts backup_dir changed=0 f
    ts="$(date +%Y%m%dT%H%M%S)"
    backup_dir="$state/dns_migration_backup/$ts"

    # --- what would change? (decide before touching anything) ---------------
    local wg_files=() nm_conns=() yaml_files=()
    local resolved_dropin="$etc/systemd/resolved.conf.d/90-geomaxima-fallback-dns.conf"
    local openresolv_conf="$etc/resolvconf.conf"
    local resolvconf_tail="$etc/resolvconf/resolv.conf.d/tail"

    for f in "$etc"/wireguard/*.conf; do
        [[ -f "$f" ]] && grep -qiE '^[[:space:]]*DNS[[:space:]]*=' "$f" && wg_files+=("$f")
    done

    local nm_ok=0
    if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
        nm_ok=1
        local uuid dns
        while IFS= read -r uuid; do
            [[ -n "$uuid" ]] || continue
            dns="$(nmcli -g ipv4.dns connection show "$uuid" 2>/dev/null | tr ',' ' ')"
            _gm_has_injected_pair $dns && nm_conns+=("$uuid")
        done < <(nmcli -g UUID connection show 2>/dev/null)
    fi

    local py_yaml=0
    if compgen -G "$etc/netplan/*.yaml" >/dev/null; then
        if python3 -c 'import yaml' 2>/dev/null; then
            py_yaml=1
            for f in "$etc"/netplan/*.yaml; do
                _gm_netplan_edit "$f" --check 2>/dev/null && yaml_files+=("$f")
            done
        else
            _gm_dns_warn "python3-yaml is not available - cannot check /etc/netplan/*.yaml for injected nameservers. NetworkManager profiles are still cleaned."
        fi
    fi

    local fix_resolved=0 fix_openresolv=0 fix_tail=0 fix_options=0
    [[ -f "$resolved_dropin" ]] && fix_resolved=1
    [[ -f "$openresolv_conf" ]] && grep -q '^append_nameservers="8\.8\.8\.8 1\.1\.1\.1"' "$openresolv_conf" && fix_openresolv=1
    [[ -f "$resolvconf_tail" ]] && grep -q 'Added by RPI-BS' "$resolvconf_tail" && fix_tail=1
    local openresolv_active=0
    if command -v resolvconf >/dev/null 2>&1 \
       && dpkg -S "$(readlink -f "$(command -v resolvconf)")" 2>/dev/null | grep -q '^openresolv:'; then
        openresolv_active=1
        grep -qx "resolv_conf_options=\"$GM_RESOLV_OPTIONS\"" "$openresolv_conf" 2>/dev/null || fix_options=1
    fi

    if (( ${#wg_files[@]} + ${#nm_conns[@]} + ${#yaml_files[@]} + fix_resolved + fix_openresolv + fix_tail + fix_options == 0 )); then
        _gm_dns_log "nothing to migrate: no WireGuard DNS lines, no injected public resolvers, resolver options already set."
        _gm_dns_report_state "unchanged" ""
        return 0
    fi

    # --- baseline ------------------------------------------------------------
    local before after wg_ifaces=() wg_up_before=()
    # Short retry window: the pre-migration state is intermittent by nature
    # (8.8.8.8 answered ~1 in 4 on the affected network).
    before="$(_gm_dns_probe "${GM_DNS_BEFORE_SECONDS:-10}")"
    for f in "${wg_files[@]}"; do
        local iface; iface="$(basename "$f" .conf)"
        wg_ifaces+=("$iface")
        if _gm_wg_up "$iface"; then wg_up_before+=("$iface"); fi
    done
    _gm_dns_log "migration starting: resolvable test hosts before = $before/${#GM_DNS_TEST_HOSTS[@]}; current nameservers: $(_gm_dns_nameservers | tr '\n' ' ')"
    mkdir -p "$backup_dir" || { _gm_err_state "cannot create $backup_dir - aborting without changes"; return 1; }

    # --- 1. WireGuard: drop DNS lines, deregister the resolvconf entry -------
    # wg-quick reads DNS= only at up/down, so the running tunnel is not
    # touched. With the line gone, the next `wg-quick up` has no DNS to
    # register (wg-quick only calls resolvconf when DNS is set), and the
    # next `wg-quick down` no longer calls `resolvconf -d` - so the stale
    # registration is removed here, explicitly.
    local iface regfile
    for f in "${wg_files[@]}"; do
        iface="$(basename "$f" .conf)"
        cp -p "$f" "$backup_dir/$(basename "$f")" \
            && cp -p "$f" "$f.dns-removed.$ts.bak" \
            && sed -i -E '/^[[:space:]]*DNS[[:space:]]*=/Id' "$f" \
            && _gm_dns_log "removed DNS line from $f (backup: $f.dns-removed.$ts.bak)" \
            || { _gm_dns_err "could not edit $f"; continue; }
        changed=1
        for regfile in "$run/resolvconf/interfaces/$iface" "$run/resolvconf/interfaces/tun.$iface"; do
            [[ -f "$regfile" ]] && cp -p "$regfile" "$backup_dir/resolvconf-$(basename "$regfile")"
        done
        if command -v resolvconf >/dev/null 2>&1; then
            resolvconf -d "$iface" -f 2>/dev/null
            resolvconf -d "tun.$iface" -f 2>/dev/null
            _gm_dns_log "deregistered resolvconf entry for $iface (no WireGuard restart)"
        fi
    done

    # --- 2. NetworkManager profiles: remove the injected pair ----------------
    # With NetworkManager's netplan integration this also rewrites the
    # matching /etc/netplan/90-NM-*.yaml; the YAML pass below covers systems
    # without it and any other YAML file carrying the pair.
    local dev devices=()
    for uuid in "${nm_conns[@]}"; do
        nmcli -g ipv4.dns connection show "$uuid" > "$backup_dir/nm-$uuid.ipv4.dns" 2>/dev/null
        local args=() a
        for a in "${GM_INJECTED_DNS[@]}"; do args+=(-ipv4.dns "$a"); done
        if nmcli connection modify "$uuid" "${args[@]}" 2>/dev/null; then
            _gm_dns_log "removed ${GM_INJECTED_DNS[*]} from NetworkManager connection $uuid"
            changed=1
            dev="$(nmcli -g GENERAL.DEVICES connection show "$uuid" 2>/dev/null)"
            [[ -n "$dev" ]] && devices+=("$dev")
        else
            _gm_dns_err "nmcli could not modify connection $uuid"
        fi
    done

    # --- 3. netplan YAML ------------------------------------------------------
    local yaml_changed=0
    if (( py_yaml )); then
        for f in "$etc"/netplan/*.yaml; do
            _gm_netplan_edit "$f" --check 2>/dev/null || continue
            cp -p "$f" "$backup_dir/netplan-$(basename "$f")"
            if _gm_netplan_edit "$f"; then
                _gm_dns_log "removed ${GM_INJECTED_DNS[*]} from $f"
                yaml_changed=1; changed=1
            else
                _gm_dns_err "could not rewrite $f - left unchanged"
            fi
        done
    fi

    # --- 4. other injected fallbacks ------------------------------------------
    if (( fix_resolved )); then
        cp -p "$resolved_dropin" "$backup_dir/" && rm -f "$resolved_dropin" && changed=1
        systemctl reload-or-restart systemd-resolved 2>/dev/null
        _gm_dns_log "removed $resolved_dropin"
    fi
    if (( fix_openresolv || fix_options )); then
        cp -p "$openresolv_conf" "$backup_dir/resolvconf.conf" 2>/dev/null
        if (( fix_openresolv )); then
            sed -i -e '/^# Added by RPI-BS - DNS resilience fallback\.$/d' \
                   -e '/^# DHCP-provided nameserver lines remain primary; these are appended$/d' \
                   -e "/^# (fallback) only, per openresolv's own append_nameservers mechanism\.\$/d" \
                   -e '/^append_nameservers="8\.8\.8\.8 1\.1\.1\.1"$/d' "$openresolv_conf"
            _gm_dns_log "removed append_nameservers fallback from $openresolv_conf"
        fi
        if (( fix_options )); then
            sed -i '/^resolv_conf_options=/d' "$openresolv_conf"
            echo "resolv_conf_options=\"$GM_RESOLV_OPTIONS\"" >> "$openresolv_conf"
            _gm_dns_log "set resolv_conf_options=\"$GM_RESOLV_OPTIONS\" in $openresolv_conf"
        fi
        changed=1
    fi
    if (( fix_tail )); then
        cp -p "$resolvconf_tail" "$backup_dir/resolvconf-tail" && : > "$resolvconf_tail" && changed=1
        _gm_dns_log "emptied $resolvconf_tail (it only held the injected fallback)"
    fi

    # --- 5. apply without dropping the link ------------------------------------
    # `netplan apply` can take interfaces down/up - unacceptable on a remote
    # station. `netplan generate` only re-renders the NetworkManager profiles
    # under /run, `nmcli connection reload` re-reads them, and
    # `nmcli device reapply` pushes the new DNS to the running device
    # without deactivating it.
    if (( yaml_changed )) && command -v netplan >/dev/null 2>&1; then
        netplan generate 2>&1 | sed 's/^/[dns] netplan: /'
    fi
    if (( nm_ok )) && (( ${#nm_conns[@]} + yaml_changed > 0 )); then
        nmcli connection reload 2>/dev/null
        if (( ${#devices[@]} == 0 )); then
            mapfile -t devices < <(nmcli -g DEVICE,STATE device status 2>/dev/null | awk -F: '$2=="connected"{print $1}')
        fi
        for dev in $(printf '%s\n' "${devices[@]}" | tr ',' '\n' | sort -u); do
            [[ " ${wg_ifaces[*]} " == *" $dev "* ]] && continue
            nmcli device reapply "$dev" >/dev/null 2>&1 \
                && _gm_dns_log "reapplied $dev (no link bounce)" \
                || _gm_dns_warn "nmcli device reapply $dev failed - the change takes effect at the next DHCP renewal"
        done
    fi
    if (( openresolv_active )); then
        resolvconf -u 2>/dev/null
    fi

    # --- 6. verify ---------------------------------------------------------------
    # The NetworkManager -> resolvconf hand-off is asynchronous, and the
    # router's upstream can be slow, so each host gets retries over the
    # whole settle window and counts as resolved if any attempt succeeds.
    after="$(_gm_dns_probe "${GM_DNS_SETTLE_SECONDS:-30}")"
    local tunnel_lost=""
    for iface in "${wg_up_before[@]}"; do
        _gm_wg_up "$iface" || tunnel_lost+=" $iface"
    done
    _gm_dns_log "resolvable test hosts after = $after/${#GM_DNS_TEST_HOSTS[@]}; nameservers now: $(_gm_dns_nameservers | tr '\n' ' ')"

    # Roll back ONLY if (a) a tunnel that was up went down, or (b) the
    # network's own DNS resolves NOTHING while the old config resolved at
    # least one host. A partial result (e.g. 4/4 by luck before, 3/4 after
    # because one lookup via the router is slow) is NOT a reason: rolling
    # back would restore the broken, policy-violating configuration.
    if [[ -n "$tunnel_lost" ]] || (( after == 0 && before >= 1 )); then
        local why="${tunnel_lost:+tunnel down:$tunnel_lost}"
        (( after == 0 && before >= 1 )) && why="${why:+$why; }the network's own DNS resolved 0/${#GM_DNS_TEST_HOSTS[@]} test hosts (the old config resolved $before)"
        _gm_dns_err "rolling back all DNS changes from $backup_dir: $why"
        _gm_dns_rollback "$backup_dir" "${wg_files[@]}"
        _gm_dns_report_state "rolled_back" "$why"
        # Surface it: the station's own network DNS not working is exactly
        # what must be visible. The watchdog raises an incident from this
        # flag on its next run and shows it on the DNS card.
        _gm_dns_status_for_ui "failed" "Network DNS not working - DNS migration rolled back ($why)"
        return 0    # a handled outcome, already recorded as rolled_back
    fi

    if [[ -z "$(_gm_dns_nameservers)" ]]; then
        _gm_dns_err "the network provides NO DNS server (no nameserver in resolv.conf). By policy no public resolver is added - fix DHCP/static DNS on the station's network."
        _gm_dns_report_state "no_dns" "network provides no DNS server"
        _gm_dns_status_for_ui "no_dns" "The network provides no DNS server. By policy no public resolver is added - fix DHCP or the station's static DNS setting."
        return 0
    fi
    if (( after == 0 )); then
        _gm_dns_err "no test host resolves through the network's DNS ($(_gm_dns_nameservers | tr '\n' ' ')). By policy no public resolver is added."
        _gm_dns_report_state "failed" "no test host resolves"
        _gm_dns_status_for_ui "failed" "Network DNS not working: no test host resolves via $(_gm_dns_nameservers | tr '\n' ' ')"
        return 0
    fi
    _gm_dns_log "migration done: resolvable $before -> $after/${#GM_DNS_TEST_HOSTS[@]}, backups in $backup_dir"
    _gm_dns_report_state "migrated" "resolvable $before -> $after"
    return 0
}

# _gm_netplan_edit <file> [--check]: remove the injected pair from every
# nameservers.addresses list in a netplan YAML file (only lists holding
# BOTH addresses). --check: exit 0 if the file contains such a list.
# Rewriting loses YAML comments; the file's mode is preserved.
_gm_netplan_edit() {
    python3 - "$1" "${2:-}" "${GM_INJECTED_DNS[@]}" <<'PYEOF'
import os, sys, yaml
path, mode, injected = sys.argv[1], sys.argv[2], set(sys.argv[3:])
with open(path) as f:
    doc = yaml.safe_load(f)
found = False
def walk(node):
    global found
    if isinstance(node, dict):
        ns = node.get('nameservers')
        if isinstance(ns, dict) and isinstance(ns.get('addresses'), list) \
                and injected <= {str(a) for a in ns['addresses']}:
            found = True
            if mode != '--check':
                ns['addresses'] = [a for a in ns['addresses'] if str(a) not in injected]
                if not ns['addresses']:
                    del ns['addresses']
                if not ns:
                    del node['nameservers']
        for v in list(node.values()):
            walk(v)
    elif isinstance(node, list):
        for v in node:
            walk(v)
walk(doc)
if mode == '--check':
    sys.exit(0 if found else 1)
if found:
    st = os.stat(path)
    tmp = path + '.tmp'
    with open(tmp, 'w') as f:
        yaml.safe_dump(doc, f, default_flow_style=False, sort_keys=False)
    os.chmod(tmp, st.st_mode & 0o7777)
    os.replace(tmp, path)
sys.exit(0)
PYEOF
}

# _gm_dns_rollback <backup_dir> <wg files...>: restore everything the
# migration touched, including the resolvconf registrations wg-quick had
# made (re-registered exactly as wg-quick did: `resolvconf -a <if> -m 0 -x`).
_gm_dns_rollback() {
    local bdir="$1"; shift
    local etc="${GM_ETC:-/etc}" f iface uuid
    for f in "$@"; do
        [[ -f "$bdir/$(basename "$f")" ]] && cp -p "$bdir/$(basename "$f")" "$f"
    done
    for f in "$bdir"/resolvconf-*; do
        [[ -f "$f" ]] || continue
        case "$(basename "$f")" in
            resolvconf-tail) cp -p "$f" "$etc/resolvconf/resolv.conf.d/tail" ;;
            *) iface="$(basename "$f")"; iface="${iface#resolvconf-}"
               resolvconf -a "$iface" -m 0 -x < "$f" 2>/dev/null ;;
        esac
    done
    [[ -f "$bdir/resolvconf.conf" ]] && cp -p "$bdir/resolvconf.conf" "$etc/resolvconf.conf"
    [[ -f "$bdir/90-geomaxima-fallback-dns.conf" ]] && cp -p "$bdir/90-geomaxima-fallback-dns.conf" "$etc/systemd/resolved.conf.d/" \
        && systemctl reload-or-restart systemd-resolved 2>/dev/null
    local yaml_restored=0
    for f in "$bdir"/netplan-*; do
        [[ -f "$f" ]] || continue
        cp -p "$f" "$etc/netplan/$(basename "$f" | sed 's/^netplan-//')" && yaml_restored=1
    done
    (( yaml_restored )) && command -v netplan >/dev/null 2>&1 && netplan generate 2>/dev/null
    for f in "$bdir"/nm-*.ipv4.dns; do
        [[ -f "$f" ]] || continue
        uuid="$(basename "$f" .ipv4.dns)"; uuid="${uuid#nm-}"
        nmcli connection modify "$uuid" ipv4.dns "$(cat "$f")" 2>/dev/null
    done
    if command -v nmcli >/dev/null 2>&1; then
        nmcli connection reload 2>/dev/null
        local dev
        for dev in $(nmcli -g DEVICE,STATE device status 2>/dev/null | awk -F: '$2=="connected"{print $1}'); do
            nmcli device reapply "$dev" >/dev/null 2>&1
        done
    fi
    command -v resolvconf >/dev/null 2>&1 && resolvconf -u 2>/dev/null
    _gm_dns_log "rollback complete"
}

# _gm_dns_report_state <result> <detail>: machine-readable record for the UI.
_gm_dns_report_state() {
    local state="${GM_STATE_DIR:-/var/lib/rtkbase}"
    mkdir -p "$state" 2>/dev/null || return 0
    printf '{"result": "%s", "detail": "%s", "timestamp": "%s", "nameservers": "%s"}\n' \
        "$1" "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(_gm_dns_nameservers | tr '\n' ' ' | sed 's/ $//')" \
        > "$state/dns_migration.json" 2>/dev/null
}
_gm_err_state() { _gm_dns_err "$1"; _gm_dns_report_state "error" "$1"; }

# _gm_dns_status_for_ui <status> <message>: write the watchdog's DNS state
# file (same format as addons/dns_health.py) with raise_incident set, so
# the next watchdog run raises the incident and the DNS card shows it.
_gm_dns_status_for_ui() {
    local state="${GM_STATE_DIR:-/var/lib/rtkbase}" ns
    mkdir -p "$state" 2>/dev/null || return 0
    ns="$(_gm_dns_nameservers | sed 's/.*/"&"/' | paste -sd, -)"
    printf '{"status": "%s", "message": "%s", "nameservers": [%s], "results": {}, "timestamp": "%s", "raise_incident": true}\n' \
        "$1" "${2//\"/\'}" "$ns" "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" > "$state/dns_status.json" 2>/dev/null
    return 0
}

# geomaxima_dns_health_check [host]: checks the system resolver and logs
# full diagnostics on failure.
#
# Returns non-zero on failure ONLY when GM_DNS_HEALTH_FATAL=1 (install.sh
# exports that: a fresh install should stop rather than cascade into apt
# errors). Otherwise it always returns 0: the OLD perform_update.sh still
# on stations calls this right after the migration and runs `exit 1` if it
# fails, which would abort the OTA before ANTEX/PRIDE and the service
# restart. The failure is still logged here and shown by the watchdog.
geomaxima_dns_health_check() {
    local test_host="${1:-deb.debian.org}"
    if timeout 12 getent hosts "$test_host" &>/dev/null; then
        return 0
    fi
    # Subshell with errexit off: a diagnostic command failing (e.g. `ls` of
    # a missing resolv.conf) must not abort a `set -e` caller.
    ( set +e; _gm_dns_health_report "$test_host" ) || true
    if [[ "${GM_DNS_HEALTH_FATAL:-0}" == 1 ]]; then
        return 1
    fi
    echo "[dns] continuing: a DNS failure is not fatal here (GM_DNS_HEALTH_FATAL is not set)" >&2
    return 0
}

_gm_dns_health_report() {
    local test_host="$1"

    if [[ -z "$(_gm_dns_nameservers)" ]]; then
        echo "ERROR: DNS resolution failed for $test_host: the network provides NO DNS server (no nameserver line in /etc/resolv.conf). By policy no public resolver is added - check DHCP or the station's static network settings." >&2
    else
        echo "ERROR: DNS resolution failed (getent hosts $test_host) via: $(_gm_dns_nameservers | tr '\n' ' ')" >&2
    fi
    echo "--- Diagnostic state ---" >&2
    ls -la "${GM_ETC:-/etc}/resolv.conf" >&2 2>&1
    echo "--- /etc/resolv.conf contents ---" >&2
    cat "${GM_ETC:-/etc}/resolv.conf" >&2 2>&1
    if command -v resolvconf >/dev/null 2>&1; then
        echo "--- resolvconf -l ---" >&2
        resolvconf -l >&2 2>&1
    fi
    echo "--- Active resolver services ---" >&2
    for svc in systemd-resolved NetworkManager systemd-networkd; do
        echo "$svc: $(systemctl is-active "$svc" 2>&1)" >&2
    done
    echo "--- End diagnostic state ---" >&2
    return 0
}
