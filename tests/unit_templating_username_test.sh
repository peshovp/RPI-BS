#!/bin/bash
#
# GeoMaxima test: render every *.service/*.timer unit template with a
# non-default username ("stationuser", never the maintainer's own
# "peshovp") and assert nothing in the rendered output still names a
# different (hardcoded) username - i.e. tools/copy_unit.sh's {user}/{home}
# substitution is the ONLY source of a username in these files.
#
# This mirrors tools/copy_unit.sh's own substitution line exactly (same
# sed expression, same placeholders) without needing root/systemctl, so it
# can run in plain CI.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TEST_USER="stationuser"
TEST_HOME="/home/${TEST_USER}"
TEST_SCRIPT_PATH="/home/${TEST_USER}/RPI-BS"
TEST_PYTHON_PATH="/home/${TEST_USER}/RPI-BS/venv/bin/python"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAIL=0
COUNT=0

for file_path in unit/*.service unit/*.timer addons/unit/*.service addons/unit/*.timer; do
    [[ -f "$file_path" ]] || continue
    file_name="$(basename "$file_path")"
    out="$WORK/$file_name"

    # Exact same substitution tools/copy_unit.sh performs.
    sed -e 's|{script_path}|'"${TEST_SCRIPT_PATH}"'|' \
        -e 's|{user}|'"${TEST_USER}"'|' \
        -e 's|{home}|'"${TEST_HOME}"'|' \
        -e 's|{python_path}|'"${TEST_PYTHON_PATH}"'|' \
        "$file_path" > "$out"

    COUNT=$((COUNT + 1))

    # No unsubstituted placeholder should remain.
    if grep -qE '\{(user|home|script_path|python_path)\}' "$out"; then
        echo "FAIL: $file_name: unsubstituted placeholder remains after templating:"
        grep -nE '\{(user|home|script_path|python_path)\}' "$out"
        FAIL=1
    fi

    # No OTHER username should appear anywhere in the rendered unit -
    # specifically never the maintainer's own "peshovp" outside a
    # github.com/peshovp URL (the maintainer's own repo - a fine,
    # permanent fact, not a station assumption), and never any literal
    # /home/<other-name>/ path that isn't TEST_HOME.
    while IFS= read -r line; do
        stripped="${line//github.com\/peshovp/}"
        stripped="${stripped//githubusercontent.com\/peshovp/}"
        if [[ "$stripped" == *peshovp* ]]; then
            echo "FAIL: $file_name: rendered unit still contains 'peshovp' with user=${TEST_USER}:"
            echo "      $line"
            FAIL=1
        fi
    done < <(grep -n "peshovp" "$out" 2>/dev/null || true)

    while IFS= read -r line; do
        if [[ "$line" =~ /home/([A-Za-z0-9_-]+)/ ]]; then
            name="${BASH_REMATCH[1]}"
            if [[ "$name" != "$TEST_USER" ]]; then
                echo "FAIL: $file_name: rendered unit references /home/$name/ instead of /home/$TEST_USER/:"
                echo "      $line"
                FAIL=1
            fi
        fi
    done < <(grep -nE '/home/[A-Za-z0-9_-]+/' "$out" 2>/dev/null || true)
done

echo ""
echo "Rendered and checked $COUNT unit file(s) with user=${TEST_USER}."

if [[ "$FAIL" -ne 0 ]]; then
    echo "RESULT: FAIL"
    exit 1
fi

echo "RESULT: PASS"
exit 0
