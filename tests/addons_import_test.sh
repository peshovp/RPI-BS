#!/usr/bin/env bash
set -uo pipefail

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not available"
    exit 0
fi

python3 - "$REPO" <<'PYEOF'
import sys
import os

REPO = sys.argv[1]
sys.path.insert(0, REPO)

PASS = 0
FAIL = 0

def ok(msg):
    global PASS
    PASS += 1
    print(f"PASS: {msg}")

def bad(msg):
    global FAIL
    FAIL += 1
    print(f"FAIL: {msg}")

# Test 1: import addons succeeds
try:
    import addons
    ok("import addons")
except ImportError as e:
    bad(f"import addons: {e}")
    sys.exit(1)

# Test 2: __all__ is empty
if addons.__all__ == []:
    ok("addons.__all__ is empty")
else:
    bad(f"addons.__all__ is not empty: {addons.__all__}")

# Test 3: legacy modules not eagerly loaded
if 'addons.controller' not in sys.modules:
    ok("addons.controller not eagerly loaded")
else:
    bad("addons.controller was eagerly loaded")

if 'addons.config' not in sys.modules:
    ok("addons.config not eagerly loaded")
else:
    bad("addons.config was eagerly loaded")

# Test 4: live feature imports work
live_imports = [
    ("addons.features.auto_survey.survey_controller", "SurveyController"),
    ("addons.features.ota_update.update_controller", "UpdateController"),
    ("addons.features.watchdog_feature", "watchdog_bp"),
    ("addons.features.watchdog_feature", "watchdog_controller"),
    ("addons.ota_service_snapshot", "write_snapshot"),
]

for module_name, attr_name in live_imports:
    try:
        module = __import__(module_name, fromlist=[attr_name])
        getattr(module, attr_name)
        ok(f"import {module_name}.{attr_name}")
    except ImportError as e:
        # Distinguish missing addons submodule from missing external dep
        if str(e).startswith("No module named 'addons") or "addons" in str(e):
            bad(f"import {module_name}.{attr_name}: {e}")
        else:
            print(f"SKIP: import {module_name}.{attr_name} (external dep missing: {e})")

print(f"RESULT: {PASS} passed, {FAIL} failed")
sys.exit(FAIL)
PYEOF

exit $?
