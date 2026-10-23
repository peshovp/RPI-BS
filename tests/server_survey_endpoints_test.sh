#!/usr/bin/env bash
set -uo pipefail
REPO="${GM_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not found"
    exit 0
fi
python3 - "$REPO" <<'PYEOF'
import ast
import sys

repo = sys.argv[1]
src_path = f"{repo}/web_app/server.py"
with open(src_path, "r") as f:
    src = f.read()

tree = ast.parse(src)
passed = 0
failed = 0

def check(name, condition):
    global passed, failed
    if condition:
        print(f"PASS: {name}")
        passed += 1
    else:
        print(f"FAIL: {name}")
        failed += 1

def get_func_source(name):
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return ast.get_source_segment(src, node)
    return None

for fn in ["auto_survey_start", "auto_survey_stop", "auto_survey_reset"]:
    source = get_func_source(fn)
    if source is None:
        check(f"{fn} exists", False)
        check(f"{fn} uses _survey_request", False)
        check(f"{fn} no direct survey calls", False)
    else:
        check(f"{fn} exists", True)
        check(f"{fn} uses _survey_request", "_survey_request(" in source)
        direct = [".start_survey(", ".stop_survey(", ".reset_survey(", ".recover_survey("]
        has_direct = any(d in source for d in direct)
        check(f"{fn} no direct survey calls", not has_direct)

ctrl_source = get_func_source("get_survey_controller")
if ctrl_source is not None:
    check("get_survey_controller no recover_survey", "recover_survey" not in ctrl_source)
else:
    check("get_survey_controller exists", False)

check("SURVEY_SERVICE_UNIT defined", 'SURVEY_SERVICE_UNIT = "geomaxima_survey.service"' in src)

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(failed)
PYEOF
exit $?
