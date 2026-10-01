#!/usr/bin/env bash
# Unit-style test for tools/dns_setup.sh's DNS migration (Part 0 of the
# PRIDE-PPPAR fix set), with nmcli, resolvconf, systemctl, getent, ip,
# dpkg, netplan and apt-get all stubbed via PATH - no real resolver config
# is touched. The stubs model the confirmed-live test-station state:
#   - /etc/wireguard/wg0.conf with "DNS = 8.8.8.8", registered by wg-quick
#     with openresolv in EXCLUSIVE mode, so resolv.conf holds only 8.8.8.8
#   - NetworkManager connection "netplan-eth0" with ipv4.dns
#     8.8.8.8,1.1.1.1 (injected by this repo's old fallback step), mirrored
#     in /etc/netplan/90-NM-<uuid>.yaml
#   - an ISP that blocks public DNS: only the router (192.168.1.1) and the
#     ISP resolvers answer
# Cases:
#   A. full migration on that state: everything injected removed, tunnel
#      untouched, resolution improves, state recorded
#   B. second run: nothing to change, no nmcli/netplan writes
#   C. the network's own DNS resolves NOTHING after the full retry window
#      while the old config resolved some -> complete rollback (files, NM,
#      resolvconf -x registration), still returns 0, "network DNS not
#      working" state for the watchdog
#   D. a single public resolver the user configured (not the injected
#      pair) is left alone
#   E. network provides no DNS at all -> ERROR, no public fallback added
#   F. geomaxima_maybe_install_openresolv never installs anything
#   G. health check names the "no DNS provided" case explicitly
#   H. before 4/4 by luck, after 3/4 with one slow host (resolved on
#      retry) and one dead host -> NOT rolled back
#   I. never fatal: a `set -e` caller continues past the migration and the
#      health check with every internal step failing; GM_DNS_HEALTH_FATAL=1
#      (install.sh) still makes the health check fail
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d /tmp/gm_dns_test.XXXXXX)"
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
chk() { if eval "$1"; then ok "$2"; else bad "$2"; fi; }

UUID=2d6e2a9c-0000-4000-8000-000000000001
mkdir -p "$W/bin"

# --- stubs -------------------------------------------------------------------
# State lives under $W/sim: nm_dns (the profile's ipv4.dns), dhcp_dns (what
# the router hands out), good_ns (resolvers that actually answer here).
cat > "$W/bin/nmcli" <<'EOF'
#!/usr/bin/env bash
S="$GM_SIM"; echo "nmcli $*" >> "$S/calls"
regen() {   # NetworkManager pushes its list (static first, then DHCP) to openresolv
    { for a in $(tr ',' ' ' < "$S/nm_dns") $(cat "$S/dhcp_dns"); do echo "nameserver $a"; done; } \
        > "$GM_RUN/resolvconf/interfaces/NetworkManager"; resolvconf -u
}
case "$*" in
  "-g UUID connection show") cat "$S/uuids" ;;
  "-g ipv4.dns connection show "*) cat "$S/nm_dns" ;;
  "-g GENERAL.DEVICES connection show "*) echo eth0 ;;
  "-g DEVICE,STATE device status") printf 'eth0:connected\nwg0:connected (externally)\nlo:unmanaged\n' ;;
  "connection modify "*" ipv4.dns "*) echo "${@: -1}" > "$S/nm_dns" ;;
  "connection modify "*)
      shift 3; cur=",$(cat "$S/nm_dns"),"
      while (( $# )); do [[ "$1" == -ipv4.dns ]] && cur="${cur//,$2,/,}"; shift 2; done
      cur="${cur#,}"; echo "${cur%,}" > "$S/nm_dns" ;;
  "connection reload") ;;
  "device reapply "*) regen; [[ -f "$S/on_reapply" ]] && bash "$S/on_reapply" ;;
  "connection up "*|"device disconnect"*|"connection down"*) echo "LINK-BOUNCE $*" >> "$S/calls" ;;
esac
exit 0
EOF
cat > "$W/bin/resolvconf" <<'EOF'
#!/usr/bin/env bash
S="$GM_SIM"; D="$GM_RUN/resolvconf/interfaces"; echo "resolvconf $*" >> "$S/calls"
case "$1" in
  -a) cat > "$D/$2"; [[ " $* " == *" -x "* ]] && echo "$2" > "$S/exclusive" ;;
  -d) rm -f "$D/$2"; [[ "$(cat "$S/exclusive" 2>/dev/null)" == "$2" ]] && rm -f "$S/exclusive" ;;
  -u) ;;
  -l) cat "$D"/* 2>/dev/null; exit 0 ;;
esac
# regenerate resolv.conf like openresolv: an exclusive entry wins outright
if [[ -f "$S/exclusive" ]]; then cat "$D/$(cat "$S/exclusive")"; else cat "$D"/* 2>/dev/null; fi \
    | awk '!seen[$0]++' > "$GM_ETC/resolv.conf"
exit 0
EOF
cat > "$W/bin/getent" <<'EOF'
#!/usr/bin/env bash
# $GM_SIM/slow_<host>: that many lookups fail first (a slow upstream);
# $GM_SIM/dead_<host>: never resolves.
[[ -f "$GM_SIM/dead_$2" ]] && exit 2
if [[ -f "$GM_SIM/slow_$2" ]]; then
    n=$(cat "$GM_SIM/slow_$2")
    if (( n > 0 )); then echo $((n - 1)) > "$GM_SIM/slow_$2"; exit 2; fi
fi
for ns in $(awk '$1=="nameserver"{print $2}' "$GM_ETC/resolv.conf"); do
    grep -qx "$ns" "$GM_SIM/good_ns" && { echo "140.82.121.4 $3"; exit 0; }
done
exit 2
EOF
cat > "$W/bin/sleep" <<'EOF'
#!/usr/bin/env bash
echo "sleep $*" >> "$GM_SIM/calls"
EOF
cat > "$W/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$GM_SIM/calls"
[[ "$1" == is-active ]] && { [[ "$*" == *NetworkManager* ]] && exit 0 || exit 3; }
exit 0
EOF
cat > "$W/bin/ip" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "link show wg0" ]] && { echo "5: wg0: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1420 state UNKNOWN"; exit 0; }
exit 1
EOF
cat > "$W/bin/dpkg" <<'EOF'
#!/usr/bin/env bash
echo "openresolv: /usr/sbin/resolvconf"
EOF
cat > "$W/bin/netplan" <<'EOF'
#!/usr/bin/env bash
echo "netplan $*" >> "$GM_SIM/calls"
EOF
cat > "$W/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "apt-get $*" >> "$GM_SIM/calls"
EOF
cat > "$W/bin/wg-quick" <<'EOF'
#!/usr/bin/env bash
echo "WG-QUICK $*" >> "$GM_SIM/calls"
EOF
chmod +x "$W"/bin/*
export PATH="$W/bin:$PATH"

# --- station fixture ---------------------------------------------------------
setup_station() {   # $1 = good resolvers, $2 = NM profile dns, $3 = DHCP dns
    local R="$W/root"; rm -rf "$R"
    export GM_ETC="$R/etc" GM_RUN="$R/run" GM_STATE_DIR="$R/state" GM_SIM="$R/sim" GM_DNS_SETTLE_SECONDS=0 GM_DNS_BEFORE_SECONDS=0
    mkdir -p "$GM_ETC/wireguard" "$GM_ETC/netplan" "$GM_RUN/resolvconf/interfaces" "$GM_SIM"
    printf '%s\n' $1 > "$GM_SIM/good_ns"
    echo "$2" > "$GM_SIM/nm_dns"; echo "$3" > "$GM_SIM/dhcp_dns"; echo "$UUID" > "$GM_SIM/uuids"
    : > "$GM_SIM/calls"
    cat > "$GM_ETC/wireguard/wg0.conf" <<'WG'
[Interface]
PrivateKey = aGVsbG8taGVsbG8taGVsbG8taGVsbG8taGVsbG8=
Address = 10.8.0.5/24
DNS = 8.8.8.8

[Peer]
PublicKey = d29ybGQtd29ybGQtd29ybGQtd29ybGQtd29ybGQ=
Endpoint = caster.example.org:51820
AllowedIPs = 10.8.0.0/24
PersistentKeepalive = 25
WG
    echo "old backup, must stay untouched" > "$GM_ETC/wireguard/wg0.conf.backup"
    cat > "$GM_ETC/netplan/90-NM-$UUID.yaml" <<YML
network:
  version: 2
  ethernets:
    NM-$UUID:
      renderer: NetworkManager
      match:
        name: eth0
      dhcp4: true
      nameservers:
        addresses:
$(for a in $(echo "$2" | tr ',' ' '); do echo "        - $a"; done)
      networkmanager:
        uuid: $UUID
        name: netplan-eth0
YML
    chmod 600 "$GM_ETC/netplan/90-NM-$UUID.yaml"
    echo "# openresolv config" > "$GM_ETC/resolvconf.conf"
    # NetworkManager's registration, then wg-quick's exclusive one
    { for a in $(echo "$2" | tr ',' ' ') $3; do echo "nameserver $a"; done; } > "$GM_RUN/resolvconf/interfaces/NetworkManager"
    echo "nameserver 8.8.8.8" | resolvconf -a wg0 -m 0 -x
    : > "$GM_SIM/calls"
}

run_migrate() { ( source "$REPO/tools/dns_setup.sh"; geomaxima_configure_dns_fallback ) > "$W/out" 2>&1; echo $? > "$W/rc"; }

echo "== Case A: live test-station state -> full migration =="
setup_station "192.168.1.1 84.54.128.100 84.54.128.9" "8.8.8.8,1.1.1.1" "192.168.1.1 84.54.128.100 84.54.128.9"
chk 'grep -qx "nameserver 8.8.8.8" "$GM_ETC/resolv.conf" && [[ $(wc -l < "$GM_ETC/resolv.conf") -eq 1 ]]' "precondition: resolv.conf holds only 8.8.8.8 (exclusive wg0 entry)"
run_migrate
chk '[[ $(cat "$W/rc") == 0 ]]' "migration returns 0"
chk '! grep -qi "^DNS" "$GM_ETC/wireguard/wg0.conf"' "DNS line removed from wg0.conf"
chk 'grep -q "^Endpoint = caster.example.org:51820" "$GM_ETC/wireguard/wg0.conf" && grep -q "^PrivateKey" "$GM_ETC/wireguard/wg0.conf"' "rest of wg0.conf kept"
chk 'ls "$GM_ETC"/wireguard/wg0.conf.dns-removed.*.bak >/dev/null 2>&1 && grep -q "^DNS = 8.8.8.8" "$GM_ETC"/wireguard/wg0.conf.dns-removed.*.bak' "timestamped backup of wg0.conf has the original DNS line"
chk '[[ "$(cat "$GM_ETC/wireguard/wg0.conf.backup")" == "old backup, must stay untouched" ]]' "older wg0.conf.backup untouched"
chk '[[ ! -f "$GM_RUN/resolvconf/interfaces/wg0" ]] && [[ ! -f "$GM_SIM/exclusive" ]]' "wg0 resolvconf registration removed (no exclusive entry left)"
chk '[[ -z "$(cat "$GM_SIM/nm_dns")" ]]' "injected 8.8.8.8/1.1.1.1 removed from the NetworkManager profile"
chk '! grep -q "8.8.8.8\|1.1.1.1\|nameservers" "$GM_ETC/netplan/90-NM-$UUID.yaml"' "nameservers removed from the netplan YAML"
chk 'grep -q "dhcp4: true" "$GM_ETC/netplan/90-NM-$UUID.yaml" && grep -q "name: netplan-eth0" "$GM_ETC/netplan/90-NM-$UUID.yaml"' "rest of the netplan YAML kept"
chk '[[ $(stat -c %a "$GM_ETC/netplan/90-NM-$UUID.yaml") == 600 ]]' "netplan YAML keeps mode 600"
chk '[[ "$(awk "\$1==\"nameserver\"{print \$2}" "$GM_ETC/resolv.conf" | tr "\n" " ")" == "192.168.1.1 84.54.128.100 84.54.128.9 " ]]' "resolv.conf now follows NetworkManager's DHCP list"
chk '! grep -q "8.8.8.8\|1.1.1.1" "$GM_ETC/resolv.conf" "$GM_ETC/resolvconf.conf"' "no public resolver left anywhere"
chk 'grep -qx "resolv_conf_options=\"timeout:2 attempts:2\"" "$GM_ETC/resolvconf.conf"' "resolver options timeout:2 attempts:2 set for openresolv"
chk 'grep -q "^netplan generate" "$GM_SIM/calls" && grep -q "^nmcli device reapply eth0" "$GM_SIM/calls"' "applied via netplan generate + nmcli device reapply"
chk '! grep -q "LINK-BOUNCE\|WG-QUICK\|netplan apply\|systemctl restart wg-quick" "$GM_SIM/calls"' "no link bounce, no netplan apply, WireGuard never restarted"
chk '! grep -q "device reapply wg0" "$GM_SIM/calls"' "wg0 itself not reapplied"
chk 'grep -q "\"result\": \"migrated\"" "$GM_STATE_DIR/dns_migration.json"' "state file records the migration"
chk 'grep -q "resolvable test hosts before = 0/4" "$W/out" && grep -q "after = 4/4" "$W/out"' "before/after resolution logged (0/4 -> 4/4)"

echo "== Case B: second run is a no-op =="
: > "$GM_SIM/calls"
run_migrate
chk 'grep -q "nothing to migrate" "$W/out"' "reports nothing to migrate"
chk '! grep -q "nmcli connection modify\|netplan generate\|device reapply\|resolvconf -d" "$GM_SIM/calls"' "no writes on second run"
chk '[[ $(ls "$GM_ETC"/wireguard/*.bak | wc -l) -eq 1 ]]' "no additional backups"

echo "== Case C: the network's own DNS resolves nothing, old config resolved some -> rollback =="
setup_station "8.8.8.8" "8.8.8.8,1.1.1.1" "192.168.1.1"
export GM_DNS_SETTLE_SECONDS=30          # full retry window (sleep is stubbed)
run_migrate
chk '[[ $(cat "$W/rc") == 0 ]]' "still returns 0 (never fatal to the OTA)"
chk 'grep -q "rolling back" "$W/out" && grep -q "resolved 0/4" "$W/out"' "rollback logged as ERROR with the reason"
chk '[[ $(grep -c "^sleep 5" "$GM_SIM/calls") -eq 6 ]]' "after-check retried over the whole 30 s window (7 attempts, 6 waits)"
chk 'grep -q "^DNS = 8.8.8.8" "$GM_ETC/wireguard/wg0.conf"' "wg0.conf DNS line restored"
chk '[[ "$(cat "$GM_SIM/exclusive" 2>/dev/null)" == wg0 ]] && grep -qx "nameserver 8.8.8.8" "$GM_RUN/resolvconf/interfaces/wg0"' "wg0 re-registered exclusively, as wg-quick had it"
chk '[[ "$(cat "$GM_SIM/nm_dns")" == "8.8.8.8,1.1.1.1" ]]' "NetworkManager profile DNS restored"
chk 'grep -q "8.8.8.8" "$GM_ETC/netplan/90-NM-$UUID.yaml"' "netplan YAML restored"
chk 'grep -q "\"result\": \"rolled_back\"" "$GM_STATE_DIR/dns_migration.json"' "dns_migration.json records rolled_back"
chk 'grep -q "\"status\": \"failed\"" "$GM_STATE_DIR/dns_status.json" && grep -q "\"raise_incident\": true" "$GM_STATE_DIR/dns_status.json" && grep -q "Network DNS not working" "$GM_STATE_DIR/dns_status.json"' "UI/incident state: network DNS not working"
chk 'python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$GM_STATE_DIR/dns_status.json"' "dns_status.json is valid JSON"
chk '! grep -q "LINK-BOUNCE\|WG-QUICK" "$GM_SIM/calls"' "rollback also never bounces link or tunnel"
export GM_DNS_SETTLE_SECONDS=0

echo "== Case H: lucky before (4/4 via 8.8.8.8), slow/partial after -> NO rollback =="
# Before: 8.8.8.8 happens to answer everything (4/4). Once the change is
# applied (hook runs at `nmcli device reapply`), lookups go via the router:
# igs.gnsswhu.cn fails once then resolves (slow upstream), igs.bkg.bund.de
# never resolves in the window. 3/4 after is not a reason to roll back.
setup_station "8.8.8.8 192.168.1.1" "8.8.8.8,1.1.1.1" "192.168.1.1"
export GM_DNS_SETTLE_SECONDS=30
printf 'touch "%s/dead_igs.bkg.bund.de"; echo 1 > "%s/slow_igs.gnsswhu.cn"\n' "$GM_SIM" "$GM_SIM" > "$GM_SIM/on_reapply"
run_migrate
chk '[[ $(cat "$W/rc") == 0 ]]' "returns 0"
chk 'grep -q "resolvable test hosts before = 4/4" "$W/out"' "before = 4/4"
chk 'grep -q "after = 3/4" "$W/out"' "after = 3/4 (slow host resolved on retry, dead host not)"
chk '! grep -q "rolling back" "$W/out"' "NOT rolled back"
chk '! grep -qi "^DNS" "$GM_ETC/wireguard/wg0.conf"' "wg0.conf stays without DNS line"
chk 'grep -q "\"result\": \"migrated\"" "$GM_STATE_DIR/dns_migration.json"' "recorded as migrated"
export GM_DNS_SETTLE_SECONDS=0

echo "== Case I: never fatal - set -e caller, every internal step failing =="
FB="$W/failbin"; mkdir -p "$FB"
for c in nmcli resolvconf netplan systemctl getent ip dpkg python3 timeout; do
    printf '#!/usr/bin/env bash\nexit 1\n' > "$FB/$c"; chmod +x "$FB/$c"
done
cp "$W/bin/sleep" "$FB/sleep"
setup_station "192.168.1.1" "8.8.8.8,1.1.1.1" "192.168.1.1"
chmod 555 "$GM_ETC/wireguard"; chmod 444 "$GM_ETC/wireguard/wg0.conf"
# I1: state dir writable, everything else failing
PATH="$FB:$PATH" bash -c 'set -e; source "$0/tools/dns_setup.sh"; geomaxima_configure_dns_fallback; echo CONTINUED-1; geomaxima_dns_health_check github.com; echo CONTINUED-2' "$REPO" > "$W/out" 2>&1
chk '[[ $? -eq 0 ]] && grep -q CONTINUED-1 "$W/out" && grep -q CONTINUED-2 "$W/out"' "set -e caller continues past migration AND health check"
# I2: state dir not writable either (the migration's own early exit)
chmod 555 "$GM_STATE_DIR" 2>/dev/null || { mkdir -p "$GM_STATE_DIR"; chmod 555 "$GM_STATE_DIR"; }
PATH="$FB:$PATH" bash -c 'set -e; source "$0/tools/dns_setup.sh"; geomaxima_configure_dns_fallback; echo CONTINUED-3' "$REPO" > "$W/out" 2>&1
chk '[[ $? -eq 0 ]] && grep -q CONTINUED-3 "$W/out"' "set -e caller continues when even the state dir is unwritable"
# I3: the migration itself returning non-zero is swallowed and recorded
chmod 755 "$GM_STATE_DIR"
bash -c 'set -e; source "$0/tools/dns_setup.sh"; geomaxima_dns_migrate() { return 7; }; geomaxima_configure_dns_fallback; echo CONTINUED-4' "$REPO" > "$W/out" 2>&1
chk '[[ $? -eq 0 ]] && grep -q CONTINUED-4 "$W/out" && grep -q "status 7" "$GM_STATE_DIR/dns_migration.json"' "non-zero migration status recorded, not propagated"
# I4: install.sh opts into a fatal health check
bash -c 'source "$0/tools/dns_setup.sh"; GM_DNS_HEALTH_FATAL=1 geomaxima_dns_health_check github.com' "$REPO" > "$W/out" 2>&1 <<<'' ; rc=$?
chk '[[ $rc -ne 0 ]]' "GM_DNS_HEALTH_FATAL=1 still makes the health check fail (install.sh)"
chmod 755 "$GM_ETC/wireguard"; chmod 644 "$GM_ETC/wireguard/wg0.conf"

echo "== Case D: a single user-chosen public resolver is left alone =="
setup_station "192.168.1.1 8.8.8.8" "8.8.8.8" "192.168.1.1"
rm -f "$GM_ETC/wireguard/wg0.conf"; rm -f "$GM_RUN/resolvconf/interfaces/wg0" "$GM_SIM/exclusive"
run_migrate
chk '[[ "$(cat "$GM_SIM/nm_dns")" == "8.8.8.8" ]]' "NetworkManager profile with only 8.8.8.8 untouched"
chk 'grep -q "8.8.8.8" "$GM_ETC/netplan/90-NM-$UUID.yaml"' "netplan YAML with only 8.8.8.8 untouched"

echo "== Case E: network provides no DNS at all =="
setup_station "" "8.8.8.8,1.1.1.1" ""
run_migrate
chk '[[ $(cat "$W/rc") == 0 ]]' "not rolled back (nothing resolved before either)"
chk 'grep -q "provides NO DNS server" "$W/out"' "ERROR names the no-DNS case"
chk 'grep -q "\"result\": \"no_dns\"" "$GM_STATE_DIR/dns_migration.json"' "state file records no_dns"
chk 'grep -q "\"status\": \"no_dns\"" "$GM_STATE_DIR/dns_status.json" && grep -q "raise_incident" "$GM_STATE_DIR/dns_status.json"' "UI/incident state: no DNS from the network"
chk '! grep -q "8.8.8.8\|1.1.1.1" "$GM_ETC/resolv.conf"' "no public fallback added"

echo "== Case F: openresolv is never installed =="
: > "$GM_SIM/calls"
( source "$REPO/tools/dns_setup.sh"; geomaxima_maybe_install_openresolv ) > "$W/out" 2>&1
chk '! grep -q "apt-get" "$GM_SIM/calls"' "no apt-get call"

echo "== Case G: health check explains the no-DNS case =="
: > "$GM_ETC/resolv.conf"
( source "$REPO/tools/dns_setup.sh"; geomaxima_dns_health_check github.com ) > "$W/out" 2>&1
chk '[[ $? -ne 0 ]] || grep -q "NO DNS server" "$W/out"' "health check fails"
chk 'grep -q "NO DNS server" "$W/out"' "health check message names the no-DNS case"

rm -rf "$W"
echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
