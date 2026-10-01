#!/usr/bin/env bash
# Unit-style test for tools/check_rtcm_height.sh against synthetic
# settings.conf + survey_state.json fixtures - no real station needed.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d /tmp/gm_rtcm_height_test.XXXXXX)"
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

run_check() {   # $1 = fake repo dir, $2 = state file (sets GM_SURVEY_STATE_FILE)
    GM_SURVEY_STATE_FILE="$2" "$REPO/tools/check_rtcm_height.sh" "$1" > "$W/out" 2>&1
    echo $?
}

echo "== Case A: matching ellipsoidal heights -> OK =="
R="$W/station_a"; mkdir -p "$R"
echo "position='42.65236966 26.43258495 208.306'" > "$R/settings.conf"
mkdir -p "$W/var_lib_a"
cat > "$W/var_lib_a/survey_state.json" <<'EOF'
{"applied": true, "applied_position": {"lat": 42.65236966, "lon": 26.43258495, "height": 208.306, "height_ellipsoidal": 208.306, "height_msl": 168.1, "broadcast_height_type": "ellipsoidal"}}
EOF
rc=$(run_check "$R" "$W/var_lib_a/survey_state.json")
cat "$W/out"
[[ "$rc" == "0" ]] && ok "Case A exits 0 (OK)" || bad "Case A exits $rc, expected 0"
grep -q "^OK:" "$W/out" && ok "Case A prints OK" || bad "Case A output missing OK: line"

echo "== Case B: ~40m mismatch (the confirmed-live regression) -> MISMATCH =="
R="$W/station_b"; mkdir -p "$R"
echo "position='42.65236966 26.43258495 168.1'" > "$R/settings.conf"  # orthometric height got written!
mkdir -p "$W/var_lib_b"
cat > "$W/var_lib_b/survey_state.json" <<'EOF'
{"applied": true, "applied_position": {"lat": 42.65236966, "lon": 26.43258495, "height": 168.1, "height_ellipsoidal": 208.306, "height_msl": 168.1, "broadcast_height_type": "orthometric"}}
EOF
rc=$(run_check "$R" "$W/var_lib_b/survey_state.json")
cat "$W/out"
[[ "$rc" == "1" ]] && ok "Case B exits 1 (MISMATCH)" || bad "Case B exits $rc, expected 1"
grep -q "^MISMATCH:" "$W/out" && ok "Case B prints MISMATCH" || bad "Case B output missing MISMATCH: line"
grep -q "40\." "$W/out" && ok "Case B reports the ~40m difference" || bad "Case B difference not shown as ~40m"

echo "== Case C: no survey state file at all -> informational, exit 0 =="
R="$W/station_c"; mkdir -p "$R"
echo "position='42.68045168 26.30807124 104.425'" > "$R/settings.conf"
rc=$(run_check "$R" "$W/does_not_exist.json")
cat "$W/out"
[[ "$rc" == "0" ]] && ok "Case C exits 0 (no state file, informational only)" || bad "Case C exits $rc, expected 0"
grep -q "No Autosurvey result has been applied on this station" "$W/out" && ok "Case C states explicitly that no survey has been applied" || bad "Case C missing the required explicit wording"

echo "== Case D: applied=false -> still compares, but warns the comparison may not be meaningful =="
R="$W/station_d"; mkdir -p "$R"
echo "position='42.65236966 26.43258495 208.306'" > "$R/settings.conf"
mkdir -p "$W/var_lib_d"
cat > "$W/var_lib_d/survey_state.json" <<'EOF'
{"applied": false, "applied_position": {"lat": 42.65236966, "lon": 26.43258495, "height": 208.306, "height_ellipsoidal": 208.306, "height_msl": 168.1, "broadcast_height_type": "ellipsoidal"}}
EOF
rc=$(run_check "$R" "$W/var_lib_d/survey_state.json")
cat "$W/out"
grep -q "NOTE:" "$W/out" && ok "Case D shows the applied=false caveat" || bad "Case D missing the applied=false note"

echo "== Case E: small (sub-1m) real-world difference -> still OK, not a false MISMATCH =="
R="$W/station_e"; mkdir -p "$R"
echo "position='42.65236966 26.43258495 208.145'" > "$R/settings.conf"
mkdir -p "$W/var_lib_e"
cat > "$W/var_lib_e/survey_state.json" <<'EOF'
{"applied": true, "applied_position": {"lat": 42.65236966, "lon": 26.43258495, "height": 208.145, "height_ellipsoidal": 208.306, "height_msl": 168.0, "broadcast_height_type": "ellipsoidal"}}
EOF
rc=$(run_check "$R" "$W/var_lib_e/survey_state.json")
cat "$W/out"
[[ "$rc" == "0" ]] && ok "Case E (0.161m diff) exits 0, not a false positive" || bad "Case E exits $rc, expected 0"

echo "== Case F: survey_state.json present but applied_position is null (never applied yet) =="
R="$W/station_f"; mkdir -p "$R"
echo "position='42.68045168 26.30807124 104.425'" > "$R/settings.conf"
mkdir -p "$W/var_lib_f"
cat > "$W/var_lib_f/survey_state.json" <<'EOF'
{"applied": false, "applied_position": null}
EOF
rc=$(run_check "$R" "$W/var_lib_f/survey_state.json")
cat "$W/out"
[[ "$rc" == "0" ]] && ok "Case F (no applied_position yet) exits 0" || bad "Case F exits $rc, expected 0"
grep -q "No Autosurvey result has been applied on this station" "$W/out" && ok "Case F states explicitly that no survey has been applied" || bad "Case F missing the required explicit wording"

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
