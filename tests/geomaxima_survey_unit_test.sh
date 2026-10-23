#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${GM_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

UNIT_FILE="$REPO/addons/unit/geomaxima_survey.service"
PASS=0
FAIL=0

ok() {
    echo "ok $1"
    PASS=$((PASS + 1))
}

bad() {
    echo "not ok $1"
    FAIL=$((FAIL + 1))
}

# Check 1: unit file exists
if [ -f "$UNIT_FILE" ]; then
    ok "unit file exists"
else
    bad "unit file exists"
fi

# Check 2: sections
if grep -q '^\[Unit\]' "$UNIT_FILE" && grep -q '^\[Service\]' "$UNIT_FILE" && grep -q '^\[Install\]' "$UNIT_FILE"; then
    ok "has [Unit], [Service], [Install] sections"
else
    bad "has [Unit], [Service], [Install] sections"
fi

# Check 3: ExecStart line and module file
if grep -q '^ExecStart={python_path} -m addons.features.auto_survey.survey_runner$' "$UNIT_FILE"; then
    ok "ExecStart line is correct"
else
    bad "ExecStart line is correct"
fi

if [ -f "$REPO/addons/features/auto_survey/survey_runner.py" ]; then
    ok "survey_runner.py module exists"
else
    bad "survey_runner.py module exists"
fi

# Check 4: KillMode
if grep -q '^KillMode=control-group$' "$UNIT_FILE"; then
    ok "KillMode=control-group is set"
else
    bad "KillMode=control-group is set"
fi

if grep -v '^\s*#' "$UNIT_FILE" | grep -q '^KillMode=process$'; then
    bad "no uncommented KillMode=process"
else
    ok "no uncommented KillMode=process"
fi

# Check 5: Restart, WantedBy, User
if grep -q '^Restart=on-failure$' "$UNIT_FILE"; then
    ok "Restart=on-failure is set"
else
    bad "Restart=on-failure is set"
fi

if grep -q '^WantedBy=multi-user.target$' "$UNIT_FILE"; then
    ok "WantedBy=multi-user.target is set"
else
    bad "WantedBy=multi-user.target is set"
fi

if grep -q '^User=root$' "$UNIT_FILE"; then
    ok "User=root is set"
else
    bad "User=root is set"
fi

# Check 6: placeholder validation
PLACEHOLDER_OK=1
while IFS= read -r ph; do
    case "$ph" in
        "{script_path}"|"{home}"|"{python_path}"|"{user}") ;;
        *)
            bad "unexpected placeholder: $ph"
            PLACEHOLDER_OK=0
            ;;
    esac
done < <(grep -v '^\s*#' "$UNIT_FILE" | grep -o '{[^}]*}' | sort -u)
if [ $PLACEHOLDER_OK -eq 1 ]; then
    ok "only allowed placeholders used"
fi

# Check 7: deployment path simulation
DEPLOYED=$(sed -e 's|{script_path}|/opt/x|' -e 's|{user}|u|' -e 's|{home}|/home/u|' -e 's|{python_path}|/opt/x/venv/bin/python|' "$UNIT_FILE")
if echo "$DEPLOYED" | grep -q '[{}]'; then
    bad "no remaining placeholders after deployment"
else
    ok "no remaining placeholders after deployment"
fi

if echo "$DEPLOYED" | grep -q '^ExecStart=/opt/x/venv/bin/python -m addons.features.auto_survey.survey_runner$'; then
    ok "deployed ExecStart is correct"
else
    bad "deployed ExecStart is correct"
fi

# Check 8: copy_unit.sh picks up the file
if grep -F 'addons/unit/*.service' "$REPO/tools/copy_unit.sh" > /dev/null; then
    ok "copy_unit.sh includes addons/unit/*.service"
else
    bad "copy_unit.sh includes addons/unit/*.service"
fi

echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
