#!/usr/bin/env bash
# Test for the daemon-reload block in tools/post_update.sh
# Verifies that units needing reload are detected, reloaded, verified,
# and restarted appropriately (except web app and str2str_file).
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
W=$(mktemp -d /tmp/gm_post_update_reload_test.XXXXXX)
cleanup() { rm -rf "$W"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

mkdir -p "$W/bin" "$W/repo/tools"

# Copy the real unit_reload.sh helper
cp "$REPO/tools/unit_reload.sh" "$W/repo/tools/unit_reload.sh"

# Stub install.sh (always succeeds)
cat > "$W/repo/tools/install.sh" << 'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$W/repo/tools/install.sh"

# Stub sudo: just exec the command
cat > "$W/bin/sudo" << 'EOF'
#!/bin/sh
exec "$@"
EOF
chmod +x "$W/bin/sudo"

# Stub systemctl driven by files in $W (via GEOMAXIMA_TEST_W env var)
cat > "$W/bin/systemctl" << 'EOF'
#!/bin/bash
W="${GEOMAXIMA_TEST_W}"

cmd="$1"
shift

case "$cmd" in
  list-unit-files)
    if [[ "$1" == "--no-legend" ]]; then
      echo "str2str_ntrip_A.service enabled"
      echo "str2str_file.service disabled"
      echo "rtkbase_web.service enabled"
      echo "rtkbase_archive.timer enabled"
      echo "geomaxima_watchdog.service enabled"
    fi
    ;;
  show)
    # Parse: show -p NeedDaemonReload --value UNIT
    unit=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -p|--property) shift ;;
        --value) ;;
        *) unit="$1" ;;
      esac
      shift
    done
    if [[ -n "$unit" && -f "$W/need" ]]; then
      if grep -qx "$unit" "$W/need"; then
        if [[ ! -f "$W/reloaded" ]] || grep -qx "$unit" "$W/stuck" 2>/dev/null; then
          echo "yes"
        else
          echo "no"
        fi
      else
        echo "no"
      fi
    else
      echo "no"
    fi
    ;;
  daemon-reload)
    echo "daemon-reload" >> "$W/calls"
    touch "$W/reloaded"
    ;;
  is-active)
    quiet=0
    unit=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --quiet) quiet=1 ;;
        *) unit="$1" ;;
      esac
      shift
    done
    if [[ -n "$unit" && -f "$W/active" ]] && grep -qx "$unit" "$W/active"; then
      if [[ $quiet -eq 1 ]]; then
        exit 0
      else
        echo "active"
      fi
    else
      if [[ $quiet -eq 1 ]]; then
        exit 1
      else
        echo "inactive"
      fi
    fi
    ;;
  is-enabled)
    echo "enabled"
    ;;
  restart)
    echo "restart $1" >> "$W/calls"
    ;;
  start)
    echo "start $1" >> "$W/calls"
    ;;
  enable)
    echo "enable $1" >> "$W/calls"
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "$W/bin/systemctl"

# Helper to run post_update.sh with given state
run_test() {
  local need_file="$1"
  local active_file="$2"
  local stuck_file="$3"

  # Reset state
  rm -f "$W/need" "$W/active" "$W/stuck" "$W/calls" "$W/reloaded" "$W/out" "$W/err"
  if [[ -n "$need_file" ]]; then
    cp "$need_file" "$W/need"
  fi
  if [[ -n "$active_file" ]]; then
    cp "$active_file" "$W/active"
  fi
  if [[ -n "$stuck_file" ]]; then
    cp "$stuck_file" "$W/stuck"
  fi

  GEOMAXIMA_TEST_W="$W" PATH="$W/bin:/usr/bin:/bin" bash "$REPO/tools/post_update.sh" "$W/repo" testuser run1 >"$W/out" 2>"$W/err"
  RC=$?
}

echo "== Case A: no units need reload =="
run_test "" "" ""
if ! grep -q "daemon-reload" "$W/calls" 2>/dev/null && ! grep -q "restart" "$W/calls" 2>/dev/null; then
  ok "Case A: no daemon-reload or restart calls"
else
  bad "Case A: unexpected daemon-reload or restart calls"
fi
if grep -q "no unit needs a daemon-reload" "$W/out"; then
  ok "Case A: correct message"
else
  bad "Case A: missing 'no unit needs a daemon-reload' message"
fi
if [[ $RC -eq 0 ]]; then
  ok "Case A: exit code 0"
else
  bad "Case A: exit code $RC"
fi
if grep -q "post_update.sh: done" "$W/out"; then
  ok "Case A: reached done"
else
  bad "Case A: did not reach done"
fi

echo "== Case B: multiple units need reload, some active =="
cat > "$W/need_b" << 'EOF'
str2str_ntrip_A.service
rtkbase_archive.timer
geomaxima_watchdog.service
EOF
cat > "$W/active_b" << 'EOF'
str2str_ntrip_A.service
rtkbase_archive.timer
EOF
run_test "$W/need_b" "$W/active_b" ""
if grep -q "daemon-reload" "$W/calls" 2>/dev/null; then
  ok "Case B: daemon-reload called"
else
  bad "Case B: daemon-reload not called"
fi
if grep -q "restart str2str_ntrip_A.service" "$W/calls" 2>/dev/null; then
  ok "Case B: str2str_ntrip_A.service restarted"
else
  bad "Case B: str2str_ntrip_A.service not restarted"
fi
if grep -q "restart rtkbase_archive.timer" "$W/calls" 2>/dev/null; then
  ok "Case B: rtkbase_archive.timer restarted"
else
  bad "Case B: rtkbase_archive.timer not restarted"
fi
if ! grep -q "restart geomaxima_watchdog.service" "$W/calls" 2>/dev/null && ! grep -q "start geomaxima_watchdog.service" "$W/calls" 2>/dev/null; then
  ok "Case B: geomaxima_watchdog.service not restarted (not active)"
else
  bad "Case B: geomaxima_watchdog.service was restarted"
fi
if grep -q "unit_reload_applied" "$W/err"; then
  ok "Case B: unit_reload_applied audit event"
else
  bad "Case B: missing unit_reload_applied audit event"
fi
if [[ $RC -eq 0 ]]; then
  ok "Case B: exit code 0"
else
  bad "Case B: exit code $RC"
fi
if grep -q "post_update.sh: done" "$W/out"; then
  ok "Case B: reached done"
else
  bad "Case B: did not reach done"
fi

echo "== Case C: web app and str2str_file need reload (should not be restarted) =="
cat > "$W/need_c" << 'EOF'
rtkbase_web.service
str2str_file.service
EOF
cat > "$W/active_c" << 'EOF'
rtkbase_web.service
str2str_file.service
EOF
run_test "$W/need_c" "$W/active_c" ""
if grep -q "daemon-reload" "$W/calls" 2>/dev/null; then
  ok "Case C: daemon-reload called"
else
  bad "Case C: daemon-reload not called"
fi
if ! grep -q "restart rtkbase_web.service" "$W/calls" 2>/dev/null && ! grep -q "restart str2str_file.service" "$W/calls" 2>/dev/null; then
  ok "Case C: web app and str2str_file not restarted"
else
  bad "Case C: web app or str2str_file was restarted"
fi
if grep -q "unit_reload_applied" "$W/err"; then
  ok "Case C: unit_reload_applied audit event"
else
  bad "Case C: missing unit_reload_applied audit event"
fi
if [[ $RC -eq 0 ]]; then
  ok "Case C: exit code 0"
else
  bad "Case C: exit code $RC"
fi
if grep -q "post_update.sh: done" "$W/out"; then
  ok "Case C: reached done"
else
  bad "Case C: did not reach done"
fi

echo "== Case D: reload does not clear NeedDaemonReload (stuck) =="
cat > "$W/need_d" << 'EOF'
str2str_ntrip_A.service
EOF
cat > "$W/active_d" << 'EOF'
str2str_ntrip_A.service
EOF
cat > "$W/stuck_d" << 'EOF'
str2str_ntrip_A.service
EOF
run_test "$W/need_d" "$W/active_d" "$W/stuck_d"
if grep -q "daemon-reload" "$W/calls" 2>/dev/null; then
  ok "Case D: daemon-reload called"
else
  bad "Case D: daemon-reload not called"
fi
if ! grep -q "restart" "$W/calls" 2>/dev/null; then
  ok "Case D: no restart calls (reload verification failed)"
else
  bad "Case D: unexpected restart calls"
fi
if grep -q "unit_reload_failed" "$W/err"; then
  ok "Case D: unit_reload_failed audit event"
else
  bad "Case D: missing unit_reload_failed audit event"
fi
if [[ $RC -eq 0 ]]; then
  ok "Case D: exit code 0"
else
  bad "Case D: exit code $RC"
fi
if grep -q "post_update.sh: done" "$W/out"; then
  ok "Case D: reached done"
else
  bad "Case D: did not reach done"
fi

echo "== Case F: unit_reload.sh helper missing =="
rm -f "$W/repo/tools/unit_reload.sh"
run_test "" "" ""
if [[ $RC -eq 0 ]]; then
  ok "Case F: exit code 0"
else
  bad "Case F: exit code $RC"
fi
if grep -q "skipping verified daemon-reload" "$W/err"; then
  ok "Case F: correct skip message"
else
  bad "Case F: missing skip message"
fi
if ! grep -q "daemon-reload" "$W/calls" 2>/dev/null; then
  ok "Case F: no daemon-reload calls"
else
  bad "Case F: unexpected daemon-reload calls"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
