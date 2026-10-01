#!/usr/bin/env bash
# =============================================================================
#  tools/check_rtcm_height.sh
#  Read-only diagnostic: does the CURRENTLY APPLIED RTCM broadcast height
#  (settings.conf's position=) match the ellipsoidal height recorded for the
#  last APPLIED Auto Survey-In result?
#
#  WHY THIS EXISTS: commit 52028a3 (2026-08-12) made Autosurvey broadcast a
#  geoid-corrected (orthometric/BGR2005) height via RTCM 1005/1006 instead of
#  the required ellipsoidal height, whenever a geoid model was loaded - a
#  confirmed ~40m systematic vertical error for every connected rover. Fixed
#  by reverting that change (see survey_controller.py's
#  _apply_geodetic_position() Step 6/8 comment for the full technical
#  reasoning). This script checks whether any station's CURRENTLY APPLIED
#  position was written while that bug was live.
#
#  It does NOT need root and does not change anything.
#
#  Usage: ./check_rtcm_height.sh [/path/to/RPI-BS]
#  (default: this script's own parent directory's parent, i.e. assumes it is
#  still at tools/check_rtcm_height.sh inside the checkout)
# =============================================================================
set -uo pipefail

REPO="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SETTINGS="$REPO/settings.conf"
# GM_SURVEY_STATE_FILE: test seam only (real runs never set it).
STATE_FILE="${GM_SURVEY_STATE_FILE:-/var/lib/rtkbase/survey_state.json}"

echo "=== RTCM broadcast height check ==="
echo "Repo:          $REPO"
echo "settings.conf: $SETTINGS"
echo "survey state:  $STATE_FILE"
echo

if [[ ! -f "$SETTINGS" ]]; then
    echo "ERROR: settings.conf not found at $SETTINGS" >&2
    exit 2
fi

applied_pos_line="$(grep -E "^position" "$SETTINGS" 2>/dev/null | head -1)"
if [[ -z "$applied_pos_line" ]]; then
    echo "ERROR: no 'position' line found in settings.conf" >&2
    exit 2
fi

# position='LAT LON HEIGHT' - strip to the three numbers.
applied_vals="$(echo "$applied_pos_line" | sed -E "s/^position\s*=\s*'?([^']*)'?.*/\1/")"
read -r applied_lat applied_lon applied_height <<< "$applied_vals"

echo "Currently applied (settings.conf):"
echo "  lat=$applied_lat lon=$applied_lon height=$applied_height m"
echo

if [[ ! -f "$STATE_FILE" ]]; then
    echo "No Autosurvey result has been applied on this station (no survey"
    echo "state file found at $STATE_FILE). The applied settings.conf position,"
    echo "if any, came from somewhere else (manual edit, install.sh default, etc)."
    exit 0
fi

# Pull the fields we need with a tiny, dependency-free parse (python3 if
# available, otherwise a grep/sed fallback - this script must run on a bare
# station with no guarantees about what's installed beyond bash).
if command -v python3 >/dev/null 2>&1; then
    read -r app_lat app_lon app_h_ellip app_h_msl app_height app_bh_type applied_flag <<EOF
$(python3 - "$STATE_FILE" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        state = json.load(f)
except Exception as e:
    print(f"PARSE_ERROR PARSE_ERROR PARSE_ERROR PARSE_ERROR PARSE_ERROR PARSE_ERROR PARSE_ERROR")
    sys.exit(0)
pos = state.get('applied_position')
applied = state.get('applied', False)
if pos is None:
    print("NO_APPLIED_SURVEY NO_APPLIED_SURVEY NO_APPLIED_SURVEY NO_APPLIED_SURVEY NO_APPLIED_SURVEY NO_APPLIED_SURVEY NO_APPLIED_SURVEY")
    sys.exit(0)
def f(key):
    v = pos.get(key)
    return 'None' if v is None else v
print(f"{f('lat')} {f('lon')} {f('height_ellipsoidal')} {f('height_msl')} {f('height')} {f('broadcast_height_type')} {applied}")
PYEOF
)
EOF
else
    echo "WARNING: python3 not found - falling back to a crude grep parse (less reliable)." >&2
    app_height=$(grep -o '"height"[[:space:]]*:[[:space:]]*[0-9.-]*' "$STATE_FILE" | tail -1 | grep -o '[0-9.-]*$')
    app_h_ellip=$(grep -o '"height_ellipsoidal"[[:space:]]*:[[:space:]]*[0-9.-]*' "$STATE_FILE" | tail -1 | grep -o '[0-9.-]*$')
    app_h_msl=$(grep -o '"height_msl"[[:space:]]*:[[:space:]]*[0-9.-]*' "$STATE_FILE" | tail -1 | grep -o '[0-9.-]*$')
    app_bh_type=$(grep -o '"broadcast_height_type"[[:space:]]*:[[:space:]]*"[a-z]*"' "$STATE_FILE" | tail -1 | grep -o '"[a-z]*"$' | tr -d '"')
    applied_flag="unknown"
    if [[ -z "${app_h_ellip:-}" ]] && ! grep -q '"applied_position"' "$STATE_FILE" 2>/dev/null; then
        echo "No Autosurvey result has been applied on this station (survey state"
        echo "file exists but records no applied_position)."
        exit 0
    fi
fi

if [[ "${app_h_ellip:-}" == "NO_APPLIED_SURVEY" ]]; then
    echo "No Autosurvey result has been applied on this station (survey state"
    echo "file exists but records no applied_position)."
    exit 0
fi

if [[ "${app_h_ellip:-}" == "PARSE_ERROR" || "${app_h_ellip:-}" == "None" || -z "${app_h_ellip:-}" ]]; then
    echo "ERROR: could not parse $STATE_FILE (empty or corrupt)." >&2
    exit 2
fi

echo "Last recorded survey result (applied_position in $STATE_FILE):"
echo "  height_ellipsoidal=${app_h_ellip:-None} height_msl=${app_h_msl:-None}"
echo "  height (actually written to settings.conf at apply time)=${app_height:-None}"
echo "  broadcast_height_type recorded=${app_bh_type:-None}"
echo "  survey 'applied' flag=${applied_flag:-unknown}"
echo

if [[ "${applied_flag:-}" != "True" && "${applied_flag:-}" != "true" ]]; then
    echo "NOTE: this survey's state says 'applied' is not True - the"
    echo "settings.conf position may have been set by something OTHER than"
    echo "this recorded survey result (manual edit, an older/different"
    echo "survey run, install.sh's default, etc). The comparison below is"
    echo "still informative but may not reflect what actually wrote the"
    echo "CURRENT settings.conf value."
    echo
fi

if [[ -z "${applied_height:-}" || -z "${app_h_ellip:-}" ]]; then
    echo "Could not extract both values needed for comparison - stopping here."
    exit 2
fi

diff=$(python3 -c "print(f'{abs(float('$applied_height') - float('$app_h_ellip')):.3f}')" 2>/dev/null)
if [[ -z "$diff" ]]; then
    # python3 fallback failed too (e.g. not installed) - try awk.
    diff=$(awk "BEGIN { d = $applied_height - ($app_h_ellip); if (d < 0) d = -d; printf \"%.3f\", d }" 2>/dev/null)
fi

echo "=== Verdict ==="
if [[ -z "$diff" ]]; then
    echo "Could not compute the difference (no python3/awk available)." >&2
    exit 2
fi

# A real PPP-AR/PPP-static result's own re-measurement will naturally differ
# by some millimeters/centimeters from what was written at apply time
# (rounding in settings.conf's %.3f format, a slightly different later
# re-estimate, etc). A geoid-correction mix-up produces a MUCH larger
# difference - commonly 20-50+ meters for Bulgaria's geoid undulation. 1m is
# used as a generous but still unambiguous threshold: nothing legitimate
# should ever differ by that much between what was computed and what was
# written moments later in the same apply step.
THRESHOLD_M=1.0
is_mismatch=$(awk "BEGIN { print ($diff > $THRESHOLD_M) ? 1 : 0 }")

if [[ "$is_mismatch" == "1" ]]; then
    echo "MISMATCH: applied height ($applied_height m) differs from the last"
    echo "recorded survey's ellipsoidal height ($app_h_ellip m) by ${diff} m."
    echo "This exceeds the ${THRESHOLD_M}m threshold - likely a geoid-height"
    echo "mix-up (confirmed-live regression, commit 52028a3, fixed by this"
    echo "commit). Compare against height_msl=${app_h_msl:-None} above: if"
    echo "the applied height is close to height_msl instead of"
    echo "height_ellipsoidal, this station broadcast orthometric height via"
    echo "RTCM while that bug was live."
    exit 1
else
    echo "OK: applied height matches the last recorded survey's ellipsoidal"
    echo "height within ${diff} m (threshold ${THRESHOLD_M}m)."
    exit 0
fi
