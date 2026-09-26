#!/usr/bin/env bash
# Unit-style test for tools/wireguard_setup.sh's geomaxima_install_wireguard(),
# with `ip` and `apt-get` stubbed via PATH - no real packages installed, no
# real network interfaces created.
#
# Case A: kernel supports WireGuard natively -> only wireguard-tools is
#         requested via apt-get.
# Case B: kernel lacks WireGuard -> wireguard-tools AND wireguard-go are
#         requested via apt-get.
# In NEITHER case may the `wireguard` metapackage, any `linux-image*`
# package, or any `*-dkms` package ever be requested - this is the actual
# regression this test exists to catch (see tools/wireguard_setup.sh's
# header comment for why: the `wireguard` metapackage depends on
# wireguard-modules, only provided by Debian's own linux-image-* kernel
# packages, which bricked a real Orange Pi 4 Pro+ station).
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
W=/tmp/gm_wg_test; rm -rf "$W"; mkdir -p "$W/bin"
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
chk() { if eval "$1"; then ok "$2"; else bad "$2"; fi; }

# Stub apt-get: records every package name it was asked to install, in
# order, one per line, to $W/apt_install_log - never actually installs
# anything.
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

run_case() {
    # $1: "supported" or "unsupported" - controls the `ip` stub's behavior
    local kernel_support="$1"
    local log="$W/apt_install_log"; rm -f "$log"

    cat > "$W/bin/ip" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "link" && "\$2" == "add" ]]; then
    if [[ "$kernel_support" == "supported" ]]; then
        exit 0
    else
        echo "ip: unknown device type wireguard" >&2
        exit 1
    fi
fi
if [[ "\$1" == "link" && "\$2" == "del" ]]; then
    exit 0
fi
exit 1
EOF
    chmod +x "$W/bin/ip"

    ( export PATH="$W/bin:$PATH" GM_TEST_APT_LOG="$log"
      source "$REPO/tools/wireguard_setup.sh"
      geomaxima_install_wireguard ) >&2
    cat "$log" 2>/dev/null | sort -u
}

echo "== Case A: kernel supports WireGuard natively =="
INSTALLED_A=$(run_case supported)
echo "$INSTALLED_A" | sed 's/^/    installed: /'
chk '[[ "$INSTALLED_A" == *wireguard-tools* ]]' "wireguard-tools requested"
chk '[[ "$INSTALLED_A" != *wireguard-go* ]]' "wireguard-go NOT requested (kernel already supports it)"
chk '! grep -qxF "wireguard" <<< "$INSTALLED_A"' "the 'wireguard' metapackage is NEVER requested"
chk '! grep -qE "^linux-image" <<< "$INSTALLED_A"' "no linux-image* package is ever requested"
chk '! grep -qE "\-dkms$" <<< "$INSTALLED_A"' "no *-dkms package is ever requested"

echo "== Case B: kernel lacks WireGuard (e.g. Orange Pi 4 Pro+ vendor kernel) =="
INSTALLED_B=$(run_case unsupported)
echo "$INSTALLED_B" | sed 's/^/    installed: /'
chk '[[ "$INSTALLED_B" == *wireguard-tools* ]]' "wireguard-tools requested"
chk '[[ "$INSTALLED_B" == *wireguard-go* ]]' "wireguard-go requested (userspace fallback)"
chk '! grep -qxF "wireguard" <<< "$INSTALLED_B"' "the 'wireguard' metapackage is NEVER requested"
chk '! grep -qE "^linux-image" <<< "$INSTALLED_B"' "no linux-image* package is ever requested"
chk '! grep -qE "\-dkms$" <<< "$INSTALLED_B"' "no *-dkms package is ever requested"

rm -rf "$W"
echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
