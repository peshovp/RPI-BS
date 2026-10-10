#!/usr/bin/env bash
# Verifies unit/rtkbase_archive.service's ReadWritePaths grants exactly
# the audit.log file (not the whole /var/lib/rtkbase directory) and is
# syntactically valid under systemd-analyze verify.
#
# LINUX-ONLY: requires systemd-analyze (not available/meaningful under
# Git Bash/Windows). Confirmed passing on WSL Ubuntu 24.04 this session.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

if ! command -v systemd-analyze >/dev/null 2>&1; then
  echo "SKIP: systemd-analyze not available in this environment"
  exit 0
fi

UNIT_FILE="$REPO/unit/rtkbase_archive.service"

echo "== Case A: ReadWritePaths contains exactly the audit.log file, not the whole directory =="
grep -q "^ReadWritePaths={script_path} -/var/lib/rtkbase/audit.log$" "$UNIT_FILE" && \
  ok "ReadWritePaths grants {script_path} + the single audit.log file only" || \
  bad "ReadWritePaths line does not match the expected scoped grant"
grep -qE "^ReadWritePaths=.*\/var\/lib\/rtkbase\s*$" "$UNIT_FILE" && \
  bad "ReadWritePaths grants the WHOLE /var/lib/rtkbase directory - too broad" || \
  ok "ReadWritePaths does NOT grant the whole /var/lib/rtkbase directory"

echo "== Case B: rendered unit file passes systemd-analyze verify =="
W="$(mktemp -d /tmp/gm_unit_verify_test.XXXXXX)"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

mkdir -p "$W/opt/rtkbase"
cat > "$W/opt/rtkbase/archive_and_clean.sh" << 'EOF'
#!/bin/bash
EOF
chmod +x "$W/opt/rtkbase/archive_and_clean.sh"

sed -e "s#{script_path}#$W/opt/rtkbase#g" -e "s/{user}/root/g" "$UNIT_FILE" > "$W/rendered.service"
if systemd-analyze verify "$W/rendered.service" > "$W/verify_out.log" 2>&1; then
  ok "systemd-analyze verify passes on the rendered unit file"
else
  cat "$W/verify_out.log"
  bad "systemd-analyze verify failed on the rendered unit file"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
