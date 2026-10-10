#!/usr/bin/env bash
# Unit-style test for addons/features/watchdog/monitors/gnss_monitor.py's
# raw-data-freshness check (2026-10-05 archive incident fix) and for
# WatchdogController's config merge bringing the new keys to an existing
# station's saved watchdog_config.json that predates them.
#
# LINUX-ONLY NOTE: this test uses `touch -d`/`stat -c` (GNU coreutils
# syntax) and mocks `systemctl` - it is written for, and should only be
# run on, Debian/Raspberry Pi OS (the real station's OS), same as every
# other *_test.sh in this directory. It is not expected to run correctly
# under Git Bash/MSYS on Windows (BSD-style `stat`/`date` differences) -
# see this commit's own root-cause note on that.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

PYTHON=python3
if ! command -v "$PYTHON" >/dev/null 2>&1 || ! "$PYTHON" -c "import serial" >/dev/null 2>&1; then
  echo "SKIP: no python3 with pyserial available in this environment"
  exit 0
fi

W="$(mktemp -d /tmp/gm_gnss_monitor_test.XXXXXX)"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

# Fake systemctl controlling str2str_file.service's is-active result via
# an env-var-named state file, so each python invocation below can pick
# a different simulated state without touching the real system.
mkdir -p "$W/bin"
cat > "$W/bin/systemctl" << 'MOCKEOF'
#!/usr/bin/env bash
if [[ "$1" == "is-active" && "$2" == "str2str_file.service" ]]; then
  state_file="${GM_TEST_STR2STR_FILE_STATE:-/nonexistent}"
  if [[ -f "$state_file" ]] && [[ "$(cat "$state_file")" == "active" ]]; then
    exit 0
  fi
  exit 3
fi
exit 0
MOCKEOF
chmod +x "$W/bin/systemctl"
export PATH="$W/bin:$PATH"

run_py() {
  # $1 = data_dir, $2 = systemctl mock state file (exported for the
  # mock systemctl script this function's own subshell inherits)
  GM_TEST_STR2STR_FILE_STATE="$2" "$PYTHON" - "$REPO" "$1" << 'PYEOF'
import sys, importlib.util
repo, data_dir = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location(
    "gnss_monitor", repo + "/addons/features/watchdog/monitors/gnss_monitor.py")
gnss_monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gnss_monitor)
GNSSMonitor = gnss_monitor.GNSSMonitor

config = {
    'enabled': True,
    'check_data_stream': False,
    'check_raw_data_freshness': True,
    'data_dir': data_dir,
}
mon = GNSSMonitor(config)
results = {'status': 'ok', 'receiver': {}, 'incidents': []}
mon._check_raw_data_freshness(results)
print("STATUS", results['status'])
for inc in results['incidents']:
    print("INCIDENT", inc['type'], inc['severity'])
print("RECEIVER_KEYS", sorted(results['receiver'].keys()))
PYEOF
}

echo "== Case A: str2str_file active, fresh raw file (1 min old) -> ok =="
D="$W/case_a"; mkdir -p "$D"
touch "$D/2026-10-06_00-00-00_GNSS-1.ubx"
echo "active" > "$W/str2str_file_state_a"
OUT=$(run_py "$D" "$W/str2str_file_state_a")
echo "$OUT"
echo "$OUT" | grep -q "^STATUS ok" && ok "Case A: status ok (fresh + active)" || bad "Case A: expected ok status"
echo "$OUT" | grep -q "^INCIDENT" && bad "Case A: unexpected incident raised" || ok "Case A: no incident raised"

echo "== Case B: str2str_file active, raw file 150 min old (>120 critical) -> critical =="
D="$W/case_b"; mkdir -p "$D"
f="$D/2026-10-05_00-00-00_GNSS-1.ubx"
touch "$f"
old_epoch=$(( $(date +%s) - 150*60 ))
touch -d "@${old_epoch}" "$f" 2>/dev/null || python3 -c "import os; os.utime('$f', ($old_epoch, $old_epoch))"
echo "active" > "$W/str2str_file_state_b"
OUT=$(run_py "$D" "$W/str2str_file_state_b")
echo "$OUT"
echo "$OUT" | grep -q "^STATUS critical" && ok "Case B: status critical (150min stale, active)" || bad "Case B: expected critical status"
echo "$OUT" | grep -q "^INCIDENT raw_data_stale critical" && ok "Case B: raw_data_stale critical incident raised" || bad "Case B: missing critical incident"

echo "== Case C: str2str_file active, raw file 45 min old (>30 warning, <120 critical) -> warning =="
D="$W/case_c"; mkdir -p "$D"
f="$D/2026-10-05_00-00-00_GNSS-1.ubx"
touch "$f"
old_epoch=$(( $(date +%s) - 45*60 ))
python3 -c "import os; os.utime('$f', ($old_epoch, $old_epoch))"
echo "active" > "$W/str2str_file_state_c"
OUT=$(run_py "$D" "$W/str2str_file_state_c")
echo "$OUT"
echo "$OUT" | grep -q "^STATUS warning" && ok "Case C: status warning (45min stale, active)" || bad "Case C: expected warning status"
echo "$OUT" | grep -q "^INCIDENT raw_data_stale warning" && ok "Case C: raw_data_stale warning incident raised" || bad "Case C: missing warning incident"

echo "== Case D: str2str_file INACTIVE, old raw file -> no false critical (survey/user stopped it on purpose) =="
D="$W/case_d"; mkdir -p "$D"
f="$D/2026-10-01_00-00-00_GNSS-1.ubx"
touch "$f"
old_epoch=$(( $(date +%s) - 300*60 ))
python3 -c "import os; os.utime('$f', ($old_epoch, $old_epoch))"
echo "inactive" > "$W/str2str_file_state_d"
OUT=$(run_py "$D" "$W/str2str_file_state_d")
echo "$OUT"
echo "$OUT" | grep -q "^STATUS ok" && ok "Case D: status ok (inactive = expected stale, not an incident)" || bad "Case D: should be ok, not a false critical"
echo "$OUT" | grep -q "^INCIDENT" && bad "Case D: false incident raised while logging intentionally stopped" || ok "Case D: no false incident"

echo "== Case E: .zip file is newer than the real raw file but must NOT count as fresh =="
D="$W/case_e"; mkdir -p "$D"
raw="$D/2026-10-01_00-00-00_GNSS-1.ubx"
zip="$D/2026-10-01_00.zip"
touch "$raw" "$zip"
old_epoch=$(( $(date +%s) - 300*60 ))
python3 -c "import os; os.utime('$raw', ($old_epoch, $old_epoch))"
# zip is fresh (just created by the archive timer "now")
echo "active" > "$W/str2str_file_state_e"
OUT=$(run_py "$D" "$W/str2str_file_state_e")
echo "$OUT"
echo "$OUT" | grep -q "^STATUS critical" && ok "Case E: status critical - fresh .zip did NOT mask the stale raw file" || bad "Case E: a fresh .zip wrongly masked stale raw data"

echo "== Case F: data_dir does not exist -> visible warning, not silent =="
OUT=$(run_py "$W/nonexistent_dir_xyz" "$W/str2str_file_state_f_missing")
echo "$OUT"
echo "$OUT" | grep -q "^STATUS warning" && ok "Case F: missing data_dir surfaced as a warning" || bad "Case F: missing data_dir not surfaced"
echo "$OUT" | grep -q "^INCIDENT raw_data_dir_unresolved warning" && ok "Case F: raw_data_dir_unresolved incident raised" || bad "Case F: missing raw_data_dir_unresolved incident"

echo "== Case G: existing watchdog_config.json without the new keys still works (defaults merge in) =="
CFG_OUT=$("$PYTHON" - "$REPO" "$W" << 'PYEOF'
import sys, importlib.util, json, os
repo, w = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location(
    "watchdog_controller", repo + "/addons/features/watchdog/watchdog_controller.py")
wc_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wc_mod)

# Simulate an OLD saved config that predates check_raw_data_freshness/data_dir.
old_config_path = os.path.join(w, "watchdog_config.json")
with open(old_config_path, "w") as f:
    json.dump({
        "enabled": True,
        "monitors": {
            "gnss": {
                "enabled": True,
                "check_data_stream": True,
                "serial_port": "/dev/ttyACM0",
                "timeout_seconds": 30,
                "alert_on_failure": True,
            }
        }
    }, f)

controller = wc_mod.WatchdogController(config_file=old_config_path)
gnss_cfg = controller.config["monitors"]["gnss"]
print("HAS_CHECK_RAW_DATA_FRESHNESS", "check_raw_data_freshness" in gnss_cfg)
print("HAS_DATA_DIR", "data_dir" in gnss_cfg)
print("CHECK_RAW_DATA_FRESHNESS_VALUE", gnss_cfg.get("check_raw_data_freshness"))
PYEOF
)
echo "$CFG_OUT"
echo "$CFG_OUT" | grep -q "^HAS_CHECK_RAW_DATA_FRESHNESS True" && ok "Case G: check_raw_data_freshness key present after merge (old config lacked it)" || bad "Case G: missing check_raw_data_freshness after merge"
echo "$CFG_OUT" | grep -q "^HAS_DATA_DIR True" && ok "Case G: data_dir key present after merge" || bad "Case G: missing data_dir after merge"
echo "$CFG_OUT" | grep -q "^CHECK_RAW_DATA_FRESHNESS_VALUE True" && ok "Case G: check_raw_data_freshness defaults to True for an upgraded station" || bad "Case G: wrong default value after merge"

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
