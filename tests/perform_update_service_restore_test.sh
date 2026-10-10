#!/usr/bin/env bash
# Unit-style test for addons/tools/post_update.sh's service-state
# snapshot-read + restore logic (2026-10-10/13 review fix) - this logic
# used to be inlined in perform_update.sh itself, which is confirmed
# live NEVER to work that way: perform_update.sh self-copies to /tmp
# BEFORE the git reset that lands new code, and
# update_controller.py's perform_update() launches it before any
# pull/reset runs - so inlined post-update steps can never see their
# own post-reset version. post_update.sh is now a separate script,
# invoked by perform_update.sh via `cat tools/post_update.sh | bash -s`
# AFTER the reset, specifically so it is always read fresh from the
# just-updated tree. This test runs the REAL post_update.sh directly
# (not an awk-extracted fragment), confirming it works standalone with
# just its 3 positional arguments.
#
# LINUX-ONLY: mocks `systemctl`, uses GNU date syntax. Confirmed passing
# on WSL Ubuntu 24.04 this session.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

PYTHON=python3
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "SKIP: no python3 available in this environment"
  exit 0
fi

W="$(mktemp -d /tmp/gm_post_update_test.XXXXXX)"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

mkdir -p "$W/units" "$W/bin"
cat > "$W/bin/systemctl" << 'MOCKEOF'
#!/usr/bin/env bash
UNITS_DIR="$GM_TEST_UNITS_DIR"
case "$1" in
  is-active)
    state_file="$UNITS_DIR/$2.state"
    [[ -f "$state_file" ]] && cat "$state_file" || echo "inactive"
    [[ -f "$state_file" ]] && [[ "$(cat "$state_file")" == "active" ]] && exit 0 || exit 3
    ;;
  is-enabled)
    enabled_file="$UNITS_DIR/$2.enabled"
    [[ -f "$enabled_file" ]] && cat "$enabled_file" || echo "disabled"
    [[ -f "$enabled_file" ]] && [[ "$(cat "$enabled_file")" == "enabled" ]] && exit 0 || exit 1
    ;;
  start) echo "active" > "$UNITS_DIR/$2.state" ;;
  enable) echo "enabled" > "$UNITS_DIR/$2.enabled" ;;
  list-unit-files)
    for f in "$UNITS_DIR"/*.state; do
      [[ -e "$f" ]] || continue
      echo "$(basename "$f" .state) static"
    done
    ;;
  *) exit 0 ;;
esac
MOCKEOF
chmod +x "$W/bin/systemctl"

# Mock sudo (post_update.sh calls `sudo install.sh --audit-log-access`/
# `--journald-retention` - no real root available in this sandbox, so
# just make sudo a no-op passthrough that reports success, isolating
# this test to the service-state restore logic specifically).
cat > "$W/bin/sudo" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
chmod +x "$W/bin/sudo"

# Mock install.sh presence check (post_update.sh tests -x on it).
mkdir -p "$W/fake_repo/tools"
touch "$W/fake_repo/tools/install.sh"
chmod +x "$W/fake_repo/tools/install.sh"

export PATH="$W/bin:$PATH"
export GM_TEST_UNITS_DIR="$W/units"

RUN_ID="test-run-$$"
SNAPSHOT_PATH="$W/service_state_before.json"

echo "== Seed: str2str_file active+enabled; something stops+disables it before this script sees it =="
echo "active" > "$W/units/str2str_file.service.state"
echo "enabled" > "$W/units/str2str_file.service.enabled"

"$PYTHON" - "$REPO" "$SNAPSHOT_PATH" "$RUN_ID" << 'PYEOF'
import sys, importlib.util
repo, snapshot_path, run_id = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("ota_service_snapshot", repo + "/addons/ota_service_snapshot.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.SNAPSHOT_PATH = __import__("pathlib").Path(snapshot_path)
print("write_snapshot:", mod.write_snapshot(run_id=run_id))
PYEOF

echo "inactive" > "$W/units/str2str_file.service.state"
echo "disabled" > "$W/units/str2str_file.service.enabled"

echo "== Run the REAL post_update.sh directly (not an extracted fragment) =="
AUDIT_LOG="$W/audit.log"
OUT=$(bash -c "
  sed 's#/var/lib/rtkbase/audit.log#${AUDIT_LOG}#; s#/var/lib/rtkbase/ota/service_state_before.json#${SNAPSHOT_PATH}#; s#/var/lib/rtkbase/\.post_update_service_state#${W}/.post_update_service_state#' '$REPO/addons/tools/post_update.sh' > '$W/post_update_rendered.sh'
  bash '$W/post_update_rendered.sh' '$W/fake_repo' 'testuser' '$RUN_ID'
" 2>&1)
echo "$OUT"

echo "== Verify =="
[[ "$(cat "$W/units/str2str_file.service.state")" == "active" ]] && ok "str2str_file.service restored to active" || bad "str2str_file.service NOT restored to active"
[[ "$(cat "$W/units/str2str_file.service.enabled")" == "enabled" ]] && ok "str2str_file.service restored to enabled" || bad "str2str_file.service NOT restored to enabled"
echo "$OUT" | grep -q "run_id matched" && ok "pre-shutdown snapshot was used (run_id matched)" || bad "pre-shutdown snapshot was not used"
grep -q '"event": "before_update"' "$AUDIT_LOG" 2>/dev/null && ok "before_update event logged to audit.log" || bad "missing before_update audit event"
grep -q '"event": "after_update"' "$AUDIT_LOG" 2>/dev/null && ok "after_update event logged to audit.log" || bad "missing after_update audit event"

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
