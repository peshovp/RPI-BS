#!/usr/bin/env bash
# =============================================================================
#  tools/dns_setup.sh
#  Meant to be SOURCED. Defines two functions - install.sh and
#  addons/tools/perform_update.sh both call these instead of duplicating
#  DNS-resolver logic:
#
#    geomaxima_maybe_install_openresolv()
#        Installs the `openresolv` package ONLY when it is actually safe
#        and necessary to do so - never when it would fight/replace an
#        already-active resolver manager.
#
#    geomaxima_configure_dns_fallback()
#        Adds 8.8.8.8/1.1.1.1 as FALLBACK-only nameservers (never removes
#        or reorders the DHCP-provided primary), using the correct
#        mechanism for whichever resolver stack is ACTUALLY active/
#        installed - detected per-stack, not merely "does this command
#        exist".
#
#  CONFIRMED LIVE ROOT CAUSE (Orange Pi 4 Pro+, Allwinner A733, Armbian
#  Trixie): this script's own EARLIER version unconditionally installed
#  `openresolv` in install.sh's main apt-get line. On this board, network
#  is managed by systemd-networkd + systemd-resolved (NOT NetworkManager),
#  and on Debian trixie the `openresolv` and `systemd-resolved` packages
#  CONFLICT with each other - apt therefore REMOVED systemd-resolved to
#  satisfy the openresolv install ("Removing systemd-resolved ... Removing
#  /etc/resolv.conf symlink to /run/systemd/resolve/stub-resolv.conf").
#  Nothing then fed the resulting openresolv setup (systemd-networkd does
#  not integrate with openresolv the way NetworkManager/dhclient hooks
#  do), leaving /etc/resolv.conf with NO nameserver at all - the DNS-
#  fallback step then also wrote to the WRONG place (the Debian
#  `resolvconf` package's /etc/resolvconf/resolv.conf.d/tail convention,
#  which openresolv does not read at all), so the fallback resolvers never
#  took effect either. Every subsequent apt call failed with
#  "getaddrinfo (16: Device or resource busy)" / DNS resolution failures.
#
#  THE FIX, per-function:
#  - geomaxima_maybe_install_openresolv(): openresolv is installed ONLY
#    when NEITHER systemd-resolved NOR NetworkManager is active AND no
#    `resolvconf` command already exists. If systemd-resolved is active,
#    its own package already provides a `resolvectl`-backed `resolvconf`
#    compatibility shim (verified via `readlink -f "$(command -v
#    resolvconf)"` resolving under /usr/bin/resolvectl or similar) - wg-
#    quick's `DNS=` directive works through that shim without ever
#    installing the separate openresolv package. Same reasoning for
#    NetworkManager (it manages resolv.conf itself; nothing needs
#    openresolv there either).
#  - geomaxima_configure_dns_fallback(): the resolvconf branch now
#    distinguishes which resolvconf IMPLEMENTATION is actually installed
#    (via `dpkg -S` on the resolved binary path, not just "the resolvconf
#    command exists") and writes to the mechanism that implementation
#    actually reads: openresolv's own /etc/resolvconf.conf
#    append_nameservers= variable (its real, documented mechanism) for
#    openresolv, vs. the Debian resolvconf package's
#    /etc/resolvconf/resolv.conf.d/tail convention only when that
#    specific package is what's actually installed.
#
#  Idempotent and warning-only throughout - a DNS-resilience failure must
#  never fail the whole install; RTKBase's own RTCM/GNSS functions do not
#  depend on internet DNS at all.
# =============================================================================

# geomaxima_maybe_install_openresolv(): see this file's header comment.
# Never installs openresolv when it could replace/conflict with an
# already-active resolver manager. Logs which decision it made and why.
geomaxima_maybe_install_openresolv() {
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        local existing_resolvconf
        existing_resolvconf="$(command -v resolvconf 2>/dev/null || true)"
        if [[ -n "$existing_resolvconf" ]]; then
            echo "systemd-resolved is active and already provides a resolvconf compatibility shim ($(readlink -f "$existing_resolvconf" 2>/dev/null || echo "$existing_resolvconf")) - NOT installing openresolv (it conflicts with systemd-resolved on Debian trixie and would remove it)."
        else
            echo "systemd-resolved is active - NOT installing openresolv (it conflicts with systemd-resolved on Debian trixie and would remove it). wg-quick's DNS= support does not require it here."
        fi
        return 0
    fi

    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        echo "NetworkManager is active - NOT installing openresolv (NetworkManager manages /etc/resolv.conf itself; wg-quick's DNS= support does not require openresolv here)."
        return 0
    fi

    if command -v resolvconf &>/dev/null; then
        echo "A resolvconf implementation is already installed ($(readlink -f "$(command -v resolvconf)" 2>/dev/null || command -v resolvconf)) - not installing openresolv again."
        return 0
    fi

    echo "No resolver manager (systemd-resolved/NetworkManager) is active and no resolvconf implementation is installed - installing openresolv for wg-quick's DNS= support."
    apt-get install -y -qq --no-remove openresolv \
        || echo "WARNING: openresolv install failed - wg-quick's DNS= directive may not take effect. Does not affect RTCM/GNSS functions." >&2
    return 0
}

# geomaxima_configure_dns_fallback(): see this file's header comment.
# Adds 8.8.8.8/1.1.1.1 as FALLBACK-only nameservers, using the mechanism
# the ACTUALLY active/installed resolver stack actually reads.
#
# GeoMaxima: GM_ETC is a test seam (real runs never set it) - overrides
# the root that all config paths below are resolved under (default /etc),
# so a test harness can verify which file this function writes to without
# touching the real host's /etc. Behavior on a real board is unchanged.
geomaxima_configure_dns_fallback() {
    local gm_etc="${GM_ETC:-/etc}"
    if command -v resolvectl &>/dev/null && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        local resolved_dropin_dir="$gm_etc/systemd/resolved.conf.d"
        local resolved_dropin="$resolved_dropin_dir/90-geomaxima-fallback-dns.conf"
        if [ -f "$resolved_dropin" ]; then
            echo "✓ systemd-resolved fallback DNS drop-in already present at $resolved_dropin - skipping."
        else
            mkdir -p "$resolved_dropin_dir"
            cat > "$resolved_dropin" <<'EOF'
# Added by RPI-BS - DNS resilience fallback.
# DHCP-provided DNS (from the router) remains primary automatically -
# this only ADDS fallback resolvers, used when the primary one is
# unreachable/times out, per systemd-resolved's own FallbackDNS semantics.
[Resolve]
FallbackDNS=8.8.8.8 1.1.1.1
EOF
            systemctl reload-or-restart systemd-resolved 2>/dev/null \
                || echo "WARNING: failed to reload systemd-resolved after writing $resolved_dropin - fallback DNS will apply after next restart/reboot." >&2
            echo "✓ systemd-resolved fallback DNS (8.8.8.8, 1.1.1.1) configured via $resolved_dropin."
        fi
        return 0
    fi

    if command -v nmcli &>/dev/null && systemctl is-active --quiet NetworkManager 2>/dev/null; then
        local nm_active_conn
        nm_active_conn="$(nmcli -t -f NAME connection show --active 2>/dev/null | head -1)"
        if [ -z "$nm_active_conn" ]; then
            echo "WARNING: NetworkManager is active but no active connection was found - skipping fallback DNS setup." >&2
        else
            local nm_current_dns
            nm_current_dns="$(nmcli -g ipv4.dns connection show "$nm_active_conn" 2>/dev/null)"
            if [[ "$nm_current_dns" == *"8.8.8.8"* && "$nm_current_dns" == *"1.1.1.1"* ]]; then
                echo "✓ NetworkManager connection '$nm_active_conn' already has fallback DNS configured - skipping."
            else
                # ipv4.dns REPLACES the DHCP-supplied resolver list unless
                # ipv4.ignore-auto-dns stays "no" (default) - with that
                # default, NetworkManager appends these to (not instead
                # of) the DHCP-provided servers, which is exactly the
                # desired primary-then-fallback behavior.
                if nmcli connection modify "$nm_active_conn" +ipv4.dns "8.8.8.8" +ipv4.dns "1.1.1.1" 2>/dev/null \
                    && nmcli connection up "$nm_active_conn" &>/dev/null; then
                    echo "✓ NetworkManager fallback DNS (8.8.8.8, 1.1.1.1) added to connection '$nm_active_conn'."
                else
                    echo "WARNING: failed to configure NetworkManager fallback DNS on '$nm_active_conn' - continuing anyway." >&2
                fi
            fi
        fi
        return 0
    fi

    if command -v resolvconf &>/dev/null; then
        # GeoMaxima: distinguish WHICH resolvconf implementation is
        # actually installed - `command -v resolvconf` existing is not
        # enough to know which config file/mechanism it actually reads.
        # openresolv and Debian's own `resolvconf` package are two
        # entirely different implementations of the same command name,
        # with different (non-interoperable) fallback-nameserver
        # mechanisms - confirmed live: writing the Debian resolvconf
        # package's tail-file convention had NO EFFECT when openresolv
        # was the actual implementation installed.
        local resolvconf_bin resolvconf_owner_pkg
        resolvconf_bin="$(readlink -f "$(command -v resolvconf)" 2>/dev/null || command -v resolvconf)"
        resolvconf_owner_pkg="$(dpkg -S "$resolvconf_bin" 2>/dev/null | cut -d: -f1 | head -1)"
        echo "Detected resolvconf implementation: $resolvconf_bin (package: ${resolvconf_owner_pkg:-unknown})"

        if [[ "$resolvconf_owner_pkg" == "openresolv" ]]; then
            # openresolv's own documented mechanism: /etc/resolvconf.conf's
            # append_nameservers= variable, applied on the next
            # `resolvconf -u`. NOT the Debian resolvconf package's
            # resolv.conf.d/tail file - openresolv does not read that.
            local openresolv_conf="$gm_etc/resolvconf.conf"
            if [ -f "$openresolv_conf" ] && grep -q '^append_nameservers=.*8\.8\.8\.8' "$openresolv_conf" && grep -q '1\.1\.1\.1' "$openresolv_conf"; then
                echo "✓ openresolv fallback DNS already configured in $openresolv_conf - skipping."
            else
                if [ -f "$openresolv_conf" ] && grep -q '^append_nameservers=' "$openresolv_conf"; then
                    sed -i '/^append_nameservers=/d' "$openresolv_conf"
                fi
                {
                    echo "# Added by RPI-BS - DNS resilience fallback."
                    echo "# DHCP-provided nameserver lines remain primary; these are appended"
                    echo "# (fallback) only, per openresolv's own append_nameservers mechanism."
                    echo 'append_nameservers="8.8.8.8 1.1.1.1"'
                } >> "$openresolv_conf"
                resolvconf -u 2>/dev/null \
                    || echo "WARNING: 'resolvconf -u' failed after updating $openresolv_conf - fallback DNS will apply after next network restart/reboot." >&2
                echo "✓ openresolv fallback DNS (8.8.8.8, 1.1.1.1) configured via $openresolv_conf (append_nameservers)."
            fi
        elif [[ "$resolvconf_owner_pkg" == "resolvconf" ]]; then
            # The Debian resolvconf package's own documented mechanism:
            # /etc/resolvconf/resolv.conf.d/tail, appended to the END of
            # the generated /etc/resolv.conf regardless of which interface
            # supplied the DHCP nameserver, which glibc's resolver tries
            # first/primary since it appears earlier in the file.
            local resolvconf_tail_dir="$gm_etc/resolvconf/resolv.conf.d"
            local resolvconf_tail="$resolvconf_tail_dir/tail"
            if [ -f "$resolvconf_tail" ] && grep -q "8.8.8.8" "$resolvconf_tail" && grep -q "1.1.1.1" "$resolvconf_tail"; then
                echo "✓ resolvconf fallback DNS tail already present at $resolvconf_tail - skipping."
            else
                mkdir -p "$resolvconf_tail_dir"
                {
                    echo "# Added by RPI-BS - DNS resilience fallback."
                    echo "# DHCP-provided nameserver lines (added by resolvconf ABOVE this tail"
                    echo "# file's content) remain primary; these are fallback only."
                    echo "nameserver 8.8.8.8"
                    echo "nameserver 1.1.1.1"
                } > "$resolvconf_tail"
                resolvconf -u 2>/dev/null \
                    || echo "WARNING: 'resolvconf -u' failed after writing $resolvconf_tail - fallback DNS will apply after next network restart/reboot." >&2
                echo "✓ resolvconf fallback DNS (8.8.8.8, 1.1.1.1) configured via $resolvconf_tail."
            fi
        else
            echo "WARNING: resolvconf command exists but its owning package could not be determined ($resolvconf_bin) - skipping fallback DNS setup to avoid writing to the wrong mechanism. This does not affect RTKBase's own RTCM/GNSS functions." >&2
        fi
        return 0
    fi

    echo "WARNING: no supported DNS resolver stack found (systemd-resolved/NetworkManager/resolvconf) - skipping fallback DNS setup. This does not affect RTKBase's own RTCM/GNSS functions." >&2
    return 0
}

# geomaxima_dns_health_check(): quick post-change sanity check - call this
# after any step that touches resolvers (package installs, the fallback
# step above, security_setup.sh). Logs full diagnostic state and returns
# non-zero if DNS resolution is actually broken, so callers can fail loud
# instead of continuing into a cascade of confusing apt/network errors.
geomaxima_dns_health_check() {
    local test_host="${1:-deb.debian.org}"
    if getent hosts "$test_host" &>/dev/null; then
        return 0
    fi

    echo "ERROR: DNS resolution check failed (getent hosts $test_host)." >&2
    echo "--- Diagnostic state ---" >&2
    ls -la /etc/resolv.conf 2>&1 >&2
    echo "--- /etc/resolv.conf contents ---" >&2
    cat /etc/resolv.conf 2>&1 >&2
    echo "--- Active resolver services ---" >&2
    systemctl is-active systemd-resolved 2>&1 >&2
    systemctl is-active NetworkManager 2>&1 >&2
    systemctl is-active systemd-networkd 2>&1 >&2
    echo "--- End diagnostic state ---" >&2
    return 1
}
