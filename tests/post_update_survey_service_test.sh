#!/usr/bin/env bash
# Test for the survey-service block in tools/post_update.sh
# Verifies that geomaxima_survey.service is enabled/restarted appropriately
# based on its deployment and runtime state.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
W=$(mktemp -d /tmp/gm_post_update_survey_test.XXXXXX)
cleanup() { rm -rf "$W"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

mkdir -p "$W/bin" "$W/repo/tools" "$W/units"

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
    # Print nothing - no units listed
    ;;
  show)
    # Always print "no" for NeedDaemonReload
    echo "no"
    ;;
  is-enabled)
    quiet=0
    unit=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --quiet) quiet=1 ;;
        *) unit="$1" ;;
      esac
      shift
    done
    if [[ -n "$unit" && -f "$W/enabled" ]] && grep -qx "$unit" "$W/enabled"; then
      if [[ $quiet -eq 1 ]]; then
        exit 0
      else
        echo "enabled"
      fi
    else
      if [[ $quiet -eq 1 ]]; then
        exit 1
      else
        echo "disabled"
      fi
    fi
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
        exit 3
      else
        echo "inactive"
      fi
    fi
    ;;
  enable)
    now=0
    unit=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --now) now=1 ;;
        *) unit="$1" ;;
      esac
      shift
    done
    echo "enable $unit" >> "$W/calls"
    if [[ -f "$W/enable_fail" ]]; then
      exit 1
    fi
    # Add to enabled and active lists
    echo "$unit" >> "$W/enabled"
    if [[ $now -eq 1 ]]; then
      echo "$unit" >> "$W/active"
    fi
    exit 0
    ;;
  restart)
    unit="$1"
    echo "restart $unit" >> "$W/calls"
    if [[ -f "$W/restart_fail" ]]; then
      exit 1
    fi
    exit 0
    ;;
  start)
    unit="$1"
    echo "start $unit" >> "$W/calls"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "$W/bin/systemctl"

# Helper to run post_update.sh with given state
run_test() {
  local unit_file="$1"
  local enabled_file="$2"
  local active_file="$3"
  local enable_fail="$4"
  local restart_fail="$5"

  # Reset state
  rm -f "$W/enabled" "$W/active" "$W/calls" "$W/enable_fail" "$W/restart_fail" "$W/out" "$W/err"
  rm -f "$W/units/geomaxima_survey.service"

  if [[ -n "$unit_file" ]]; then
    cp "$unit_file" "$W/units/geomaxima_survey.service"
  fi
  if [[ -n "$enabled_file" ]]; then
    cp "$enabled_file" "$W/enabled"
  fi
  if [[ -n "$active_file" ]]; then
    cp "$active_file" "$W/active"
  fi
  if [[ -n "$enable_fail" ]]; then
    touch "$W/enable_fail"
  fi
  if [[ -n "$restart_fail" ]]; then
    touch "$W/restart_fail"
  fi

  GEOMAXIMA_TEST_W="$W" GEOMAXIMA_SYSTEMD_UNIT_DIR="$W/units" PATH="$W/bin:/usr/bin:/bin" bash "$REPO/tools/post_update.sh" "$W/repo" testuser run1 >"$W/out" 2>"$W/err"
  RC=$?
}

echo "== Case A: unit file absent -> no enable/restart/start =="
run_test "" "" "" "" ""
if ! grep -q "enable geomaxima_survey.service" "$W/calls" 2>/dev/null && \
   ! grep -q "restart geomaxima_survey.service" "$W/calls" 2>/dev/null && \
   ! grep -q "start geomaxima_survey.service" "$W/calls" 2>/dev/null; then
  ok "Case A: no enable/restart/start calls"
else
  bad "Case A: unexpected enable/restart/start calls"
fi
if grep -q "not deployed" "$W/err"; then
  ok "Case A: 'not deployed' message in err"
else
  bad "Case A: missing 'not deployed' message"
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

echo "== Case B: unit file present, not enabled -> enable --now =="
cat > "$W/unit_b" << 'EOF'
[Unit]
Description=GeoMaxima Survey Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/survey-service
Restart=always

[Install]
WantedBy=multi-user.target
EOF
run_test "$W/unit_b" "" "" "" ""
if grep -q "enable geomaxima_survey.service" "$W/calls" 2>/dev/null; then
  ok "Case B: enable call made"
else
  bad "Case B: enable call not made"
fi
if grep -q "survey_service_enabled" "$W/err"; then
  ok "Case B: survey_service_enabled audit event"
else
  bad "Case B: missing survey_service_enabled audit event"
fi
if ! grep -q "restart geomaxima_survey.service" "$W/calls" 2>/dev/null; then
  ok "Case B: no restart call"
else
  bad "Case B: unexpected restart call"
fi
if [[ $RC -eq 0 ]]; then
  ok "Case B: exit code 0"
else
  bad "Case B: exit code $RC"
fi

echo "== Case C: unit file present, enabled and active -> restart =="
cat > "$W/enabled_c" << 'EOF'
geomaxima_survey.service
EOF
cat > "$W/active_c" << 'EOF'
geomaxima_survey.service
EOF
run_test "$W/unit_b" "$W/enabled_c" "$W/active_c" "" ""
if grep -q "restart geomaxima_survey.service" "$W/calls" 2>/dev/null; then
  ok "Case C: restart call made"
else
  bad "Case C: restart call not made"
fi
if grep -q "survey_service_restarted" "$W/err"; then
  ok "Case C: survey_service_restarted audit event"
else
  bad "Case C: missing survey_service_restarted audit event"
fi
if ! grep -q "enable geomaxima_survey.service" "$W/calls" 2>/dev/null; then
  ok "Case C: no enable call"
else
  bad "Case C: unexpected enable call"
fi
if [[ $RC -eq 0 ]]; then
  ok "Case C: exit code 0"
else
  bad "Case C: exit code $RC"
fi

echo "== Case D: unit file present, enabled but NOT active -> leave as is =="
run_test "$W/unit_b" "$W/enabled_c" "" "" ""
if ! grep -q "enable geomaxima_survey.service" "$W/calls" 2>/dev/null && \
   ! grep -q "restart geomaxima_survey.service" "$W/calls" 2>/dev/null && \
   ! grep -q "start geomaxima_survey.service" "$W/calls" 2>/dev/null; then
  ok "Case D: no enable/restart/start calls"
else
  bad "Case D: unexpected enable/restart/start calls"
fi
if grep -q "leaving it as it was" "$W/out"; then
  ok "Case D: 'leaving it as it was' message"
else
  bad "Case D: missing 'leaving it as it was' message"
fi
if [[ $RC -eq 0 ]]; then
  ok "Case D: exit code 0"
else
  bad "Case D: exit code $RC"
fi

echo "== Case E: enable fails -> survey_service_enable_failed =="
run_test "$W/unit_b" "" "" "yes" ""
if grep -q "survey_service_enable_failed" "$W/err"; then
  ok "Case E: survey_service_enable_failed audit event"
else
  bad "Case E: missing survey_service_enable_failed audit event"
fi
if [[ $RC -eq 0 ]]; then
  ok "Case E: exit code 0"
else
  bad "Case E: exit code $RC"
fi
if grep -q "post_update.sh: done" "$W/out"; then
  ok "Case E: reached done"
else
  bad "Case E: did not reach done"
fi

echo "== Case F: restart fails -> survey_service_restart_failed =="
run_test "$W/unit_b" "$W/enabled_c" "$W/active_c" "" "yes"
if grep -q "survey_service_restart_failed" "$W/err"; then
  ok "Case F: survey_service_restart_failed audit event"
else
  bad "Case F: missing survey_service_restart_failed audit event"
fi
if [[ $RC -eq 0 ]]; then
  ok "Case F: exit code 0"
else
  bad "Case F: exit code $RC"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
