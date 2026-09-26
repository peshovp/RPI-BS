#!/usr/bin/env bash
# Unit-style test for tools/dns_setup.sh's geomaxima_maybe_install_openresolv()
# and geomaxima_configure_dns_fallback(), with `systemctl`, `apt-get`, `nmcli`,
# `dpkg`, `readlink`, and `resolvconf` all stubbed via PATH - no real
# packages installed, no real resolver config touched.
#
# Confirmed live regression this exists to catch (Orange Pi 4 Pro+, Armbian
# Trixie): installing openresolv unconditionally REMOVED the active
# systemd-resolved package (they conflict on Debian trixie), breaking DNS
# entirely; the fallback-DNS step then wrote to the Debian resolvconf
# package's tail-file convention even though openresolv (a different,
# non-interoperable implementation) was what ended up installed, so the
# fallback never took effect either.
#
# Cases:
#   A. systemd-resolved active            -> openresolv NOT installed
#   B. NetworkManager active              -> openresolv NOT installed
#   C. neither active, no resolvconf cmd  -> openresolv installed
#   D. openresolv already the resolvconf implementation -> fallback goes
#      into /etc/resolvconf.conf's append_nameservers=, NOT the Debian
#      resolvconf package's tail file
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
W=/tmp/gm_dns_test; rm -rf "$W"; mkdir -p "$W/bin" "$W/etc"
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
chk() { if eval "$1"; then ok "$2"; else bad "$2"; fi; }

# Stub apt-get: records every package name it was asked to install.
cat > "$W/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "install" ]]; then
    shift
    for arg in "$@"; do
        [[ "$arg" == -* ]] && continue
        echo "$arg" >> "$GM_TEST_APT_LOG"
    done
fi
exit 0
EOF
chmod +x "$W/bin/apt-get"

reset_stubs() {
    local active_service="$1"  # "systemd-resolved", "NetworkManager", or "" (none)
    local resolvconf_present="$2"  # "openresolv", "resolvconf", or "" (absent)

    cat > "$W/bin/systemctl" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "is-active" ]]; then
    [[ "\$3" == "$active_service" ]] && exit 0
    [[ "\$2" == "$active_service" ]] && exit 0
    exit 1
fi
if [[ "\$1" == "reload-or-restart" ]]; then exit 0; fi
exit 0
EOF
    chmod +x "$W/bin/systemctl"

    cat > "$W/bin/resolvectl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$W/bin/resolvectl"

    if [[ -n "$resolvconf_present" ]]; then
        cat > "$W/bin/resolvconf" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
        chmod +x "$W/bin/resolvconf"
        cat > "$W/bin/dpkg" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "-S" ]]; then
    echo "$resolvconf_present: \$2"
    exit 0
fi
exit 1
EOF
        chmod +x "$W/bin/dpkg"
        cat > "$W/bin/readlink" <<'EOF'
#!/usr/bin/env bash
# Simulate `readlink -f` resolving to itself (a real path) - the test
# cares about dpkg -S's output, not the actual path content.
shift
echo "$1"
EOF
        chmod +x "$W/bin/readlink"
    else
        rm -f "$W/bin/resolvconf" "$W/bin/dpkg" "$W/bin/readlink"
    fi

    cat > "$W/bin/nmcli" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-t" ]]; then echo "gm-test-conn"; exit 0; fi
if [[ "$1" == "-g" ]]; then echo ""; exit 0; fi
exit 0
EOF
    chmod +x "$W/bin/nmcli"
}

run_install() {
    ( export PATH="$W/bin:$PATH" GM_TEST_APT_LOG="$W/apt_install_log"
      rm -f "$GM_TEST_APT_LOG"
      source "$REPO/tools/dns_setup.sh"
      geomaxima_maybe_install_openresolv ) >&2
    cat "$W/apt_install_log" 2>/dev/null | sort -u
}

echo "== Case A: systemd-resolved active =="
reset_stubs "systemd-resolved" ""
INSTALLED_A=$(run_install)
chk '[[ -z "$INSTALLED_A" ]]' "openresolv NOT installed (systemd-resolved active)"

echo "== Case B: NetworkManager active =="
reset_stubs "NetworkManager" ""
INSTALLED_B=$(run_install)
chk '[[ -z "$INSTALLED_B" ]]' "openresolv NOT installed (NetworkManager active)"

echo "== Case C: neither active, no resolvconf command =="
reset_stubs "" ""
INSTALLED_C=$(run_install)
chk '[[ "$INSTALLED_C" == *openresolv* ]]' "openresolv IS installed (no resolver manager active)"

echo "== Case D: openresolv already installed - fallback goes to append_nameservers, not the Debian tail file =="
reset_stubs "" "openresolv"
rm -rf "$W/etc"; mkdir -p "$W/etc"
( export PATH="$W/bin:$PATH" GM_ETC="$W/etc"
  source "$REPO/tools/dns_setup.sh"
  geomaxima_configure_dns_fallback ) > "$W/case_d.log" 2>&1
chk 'grep -qi "openresolv" "$W/case_d.log"' "Case D: detected/logged openresolv as the resolvconf implementation"
chk 'grep -qi "append_nameservers" "$W/case_d.log"' "Case D: uses openresolv's append_nameservers mechanism"
chk '[[ -f "$W/etc/resolvconf.conf" ]]' "Case D: wrote to /etc/resolvconf.conf (openresolv's real file)"
chk 'grep -q "append_nameservers=" "$W/etc/resolvconf.conf" 2>/dev/null' "Case D: append_nameservers= line present in resolvconf.conf"
chk '[[ ! -f "$W/etc/resolvconf/resolv.conf.d/tail" ]]' "Case D: did NOT write the Debian resolvconf package's tail file"

echo "== Case E: the Debian resolvconf package (not openresolv) - fallback goes to the tail file =="
reset_stubs "" "resolvconf"
rm -rf "$W/etc"; mkdir -p "$W/etc"
( export PATH="$W/bin:$PATH" GM_ETC="$W/etc"
  source "$REPO/tools/dns_setup.sh"
  geomaxima_configure_dns_fallback ) > "$W/case_e.log" 2>&1
chk '[[ -f "$W/etc/resolvconf/resolv.conf.d/tail" ]]' "Case E: wrote the Debian resolvconf package's tail file"
chk 'grep -q "8.8.8.8" "$W/etc/resolvconf/resolv.conf.d/tail" 2>/dev/null' "Case E: tail file contains the fallback nameservers"
chk '[[ ! -f "$W/etc/resolvconf.conf" ]]' "Case E: did NOT write openresolv's resolvconf.conf"

rm -rf "$W"
echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
