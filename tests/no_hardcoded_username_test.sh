#!/bin/bash
#
# GeoMaxima CI guard: fail if the codebase contains a hardcoded developer
# username or home path.
#
# Background (confirmed-live audit, see the commit that added this test):
# several files hardcoded "peshovp" (the maintainer's own Linux/GitHub
# username) as a default user, a default deploy path
# (/home/peshovp/rtkbase/...), or a .netrc login - none of which are valid
# assumptions on a station installed under any other username. The project
# rule is: the install user is derived at runtime (SUDO_USER ->
# /etc/geomaxima/install.env's GM_INSTALL_USER -> the install dir's owner ->
# /etc/environment's rtkbase_path), never from a literal.
#
# This test greps the tracked, non-vendored, non-test source tree for:
#   1. the literal string "peshovp", EXCEPT inside a github.com/peshovp URL
#      (the maintainer's own GitHub account/repo - a fine, permanent fact,
#      not a station assumption)
#   2. a hardcoded /home/<name>/ path, EXCEPT a placeholder-looking name
#      (your_username, <user>, etc.) used only in --help text/comments
#
# Excluded from scanning: addons/PRIDE-PPPAR/ (vendored upstream source,
# not GeoMaxima code), tests/ (test fixtures/scripts are allowed to use a
# fixed example username to exercise the templating logic - see
# unit_templating_username_test.sh in this same directory), and a short
# list of upstream Stefal/Reach files this project doesn't own the content
# of (they hardcode THEIR OWN historical example users/paths, e.g. "reach",
# "pi", "stephane" - unrelated to GeoMaxima's "peshovp" audit and not
# GeoMaxima code to begin with).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FAIL=0

echo "=== Scanning for hardcoded 'peshovp' (excluding github.com/peshovp URLs) ==="

# List candidate files: tracked, matching extensions, outside the excluded dirs.
# Upstream Stefal/Reach files this project doesn't own the content of -
# they use their own historical example users, unrelated to this audit.
UPSTREAM_EXCLUDES=(
    'web_app/log_converter/convbin.py'
    'web_app/reach_tools/'
    'unit/disabled/rtkbase_update.service'
)

mapfile -t FILES < <(git ls-files -- '*.py' '*.sh' '*.service' '*.timer' '*.conf' '*.conf.*' \
    | grep -v '^addons/PRIDE-PPPAR/' \
    | grep -v '^tests/' \
    | grep -v '^OLD AutoSurvey/' || true)

FILTERED=()
for f in "${FILES[@]}"; do
    skip=0
    for ex in "${UPSTREAM_EXCLUDES[@]}"; do
        [[ "$f" == "$ex"* ]] && { skip=1; break; }
    done
    [[ "$skip" -eq 0 ]] && FILTERED+=("$f")
done
FILES=("${FILTERED[@]}")

for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || continue

    # Lines containing "peshovp" that are NOT solely a github.com/peshovp URL reference.
    # Strategy: grep all peshovp hits, then for each hit line, strip every
    # github.com/peshovp occurrence and see if "peshovp" still remains.
    while IFS= read -r line; do
        stripped="${line//github.com\/peshovp/}"
        stripped="${stripped//githubusercontent.com\/peshovp/}"
        if [[ "$stripped" == *peshovp* ]]; then
            echo "FAIL: $f: hardcoded 'peshovp' outside a GitHub URL:"
            echo "      $line"
            FAIL=1
        fi
    done < <(grep -n "peshovp" "$f" 2>/dev/null || true)
done

echo ""
echo "=== Scanning for hardcoded /home/<name>/ paths ==="

# Placeholder-style names that are fine in help text/comments (not a real
# station assumption).
PLACEHOLDER_RE='your_username|<user>|<username>|username|stationuser|example|USER|john'

for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || continue

    while IFS= read -r line; do
        # Extract the /home/<name>/ segment(s) on this line.
        while [[ "$line" =~ /home/([A-Za-z0-9_-]+)/ ]]; do
            name="${BASH_REMATCH[1]}"
            rest="${line#*"${BASH_REMATCH[0]}"}"
            if [[ ! "$name" =~ ^($PLACEHOLDER_RE)$ ]]; then
                echo "FAIL: $f: hardcoded /home/$name/ path:"
                echo "      $line"
                FAIL=1
            fi
            line="$rest"
        done
    done < <(grep -nE '/home/[A-Za-z0-9_-]+/' "$f" 2>/dev/null || true)
done

echo ""
if [[ "$FAIL" -ne 0 ]]; then
    echo "RESULT: FAIL - hardcoded username(s)/home path(s) found above."
    exit 1
fi

echo "RESULT: PASS - no hardcoded usernames or home paths found."
exit 0
