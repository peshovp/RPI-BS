#!/usr/bin/env bash
# Unit-style test for survey_controller.py's SURVEY-ONLY policy
# (_ensure_file_logging()/_stop_file_logging()): the File service is
# survey-only. The survey ALWAYS owns it: _ensure_file_logging() starts
# it when inactive (plain start, never enable) or adopts it when already
# active, and sets ownership True in every case; _stop_file_logging()
# stops it unconditionally (plain stop, never disable) and clears
# ownership. There is no "user enabled it, so the survey must not touch
# it" rule any more.
#
# LINUX-ONLY: mocks `systemctl`. Confirmed passing on WSL Ubuntu 24.04
# this session.
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

W="$(mktemp -d /tmp/gm_survey_filelog_test.XXXXXX)"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

mkdir -p "$W/bin"
cat > "$W/bin/systemctl" << 'MOCKEOF'
#!/usr/bin/env bash
# State file format: "<active_field>,<enabled_field>" e.g.
# "active,enabled" or "inactive,disabled" - split on comma, not a
# substring match (a naive *active* glob match wrongly matches
# "inactive" too, since "inactive" CONTAINS the substring "active").
STATE_FILE="$GM_TEST_STATE_FILE"
state_raw=$(cat "$STATE_FILE" 2>/dev/null)
active_field="${state_raw%%,*}"
enabled_field="${state_raw##*,}"
case "$1" in
  is-active)
    [[ "$active_field" == "active" ]] && echo "active" && exit 0
    echo "inactive"; exit 3
    ;;
  is-enabled)
    [[ "$enabled_field" == "enabled" ]] && echo "enabled" && exit 0
    echo "disabled"; exit 1
    ;;
  start)
    [[ "$enabled_field" == "enabled" ]] && echo "active,enabled" > "$STATE_FILE" || echo "active,disabled" > "$STATE_FILE"
    exit 0
    ;;
  stop)
    [[ "$enabled_field" == "enabled" ]] && echo "inactive,enabled" > "$STATE_FILE" || echo "inactive,disabled" > "$STATE_FILE"
    exit 0
    ;;
  *) exit 0 ;;
esac
MOCKEOF
chmod +x "$W/bin/systemctl"
export PATH="$W/bin:$PATH"

run_py() {
  GM_TEST_STATE_FILE="$1" "$PYTHON" - "$REPO" << 'PYEOF'
import sys, types

repo = sys.argv[1]
sys.path.insert(0, repo)

# Stub out heavy/unavailable dependencies this package's __init__ chain
# and survey_controller.py itself import, so this test can import the
# real module (as a proper package member, so its own relative imports
# resolve) without needing Flask/pyproj/numpy/etc. installed - same
# technique used elsewhere in this test suite's own Python harnesses.
class _Any:
    def __init__(self, *a, **k): pass
    def __call__(self, *a, **k): return _Any()
    def __getattr__(self, n): return _Any()
for name in ('flask', 'flask_login', 'serial', 'scipy', 'scipy.stats',
             'requests'):
    m = types.ModuleType(name)
    m.__getattr__ = lambda n: _Any()
    sys.modules.setdefault(name, m)

class _NoMatch: pass
npmod = types.ModuleType('numpy')
npmod.bool_ = _NoMatch; npmod.integer = _NoMatch; npmod.floating = _NoMatch; npmod.ndarray = _NoMatch
sys.modules.setdefault('numpy', npmod)

try:
    import pyproj  # noqa
except ImportError:
    class _FakeTransformer:
        def __init__(self, kind): self._kind = kind
        @classmethod
        def from_crs(cls, src, dst, always_xy=True): return cls('x')
        @classmethod
        def from_pipeline(cls, pipeline): return cls('x')
        def transform(self, *a): return (0.0, 0.0, 0.0)
    pyproj_mod = types.ModuleType('pyproj')
    pyproj_mod.Transformer = _FakeTransformer
    sys.modules['pyproj'] = pyproj_mod

try:
    from addons.features.auto_survey import survey_controller as mod
except Exception as e:
    print("IMPORT_FAILED", repr(e))
    sys.exit(0)

# Minimal stand-in state object - only the 2 methods
# _ensure_file_logging()/_stop_file_logging() actually call.
class FakeState:
    def __init__(self):
        self.owned = False
    def get_file_service_owned(self):
        return self.owned
    def set_file_service_owned(self, v):
        self.owned = v

class FakeController:
    pass

ctrl = FakeController()
ctrl.state = FakeState()
ctrl._ensure_file_logging = mod.SurveyController._ensure_file_logging.__get__(ctrl)
ctrl._stop_file_logging = mod.SurveyController._stop_file_logging.__get__(ctrl)
ctrl._file_logging_enabled_by_user = mod.SurveyController._file_logging_enabled_by_user.__get__(ctrl)

import logging
logging.getLogger().addHandler(logging.NullHandler())
mod.logger = logging.getLogger("test")

import os
state_file = os.environ["GM_TEST_STATE_FILE"]

print("ENSURE_RESULT", ctrl._ensure_file_logging())
print("OWNED_AFTER_ENSURE", ctrl.state.owned)
with open(state_file) as f:
    print("STATE_AFTER_ENSURE", f.read().strip())
print("STOP_RESULT", ctrl._stop_file_logging(reason="test"))
print("OWNED_AFTER_STOP", ctrl.state.owned)
with open(state_file) as f:
    print("STATE_AFTER_STOP", f.read().strip())
PYEOF
}

# Case C below: the survey claims ownership (service was off), then the
# user enables+starts the service mid-survey via the UI toggle
# (simulated by mutating the state file directly between
# _ensure_file_logging() and _stop_file_logging()), then the survey
# ends. Under the survey-only policy, the survey stops the service at
# its end regardless of mid-survey user changes.
run_py_mid_survey_enable() {
  GM_TEST_STATE_FILE="$1" "$PYTHON" - "$REPO" << 'PYEOF'
import sys, types, os

repo = sys.argv[1]
sys.path.insert(0, repo)

class _Any:
    def __init__(self, *a, **k): pass
    def __call__(self, *a, **k): return _Any()
    def __getattr__(self, n): return _Any()
for name in ('flask', 'flask_login', 'serial', 'scipy', 'scipy.stats', 'requests'):
    m = types.ModuleType(name)
    m.__getattr__ = lambda n: _Any()
    sys.modules.setdefault(name, m)

class _NoMatch: pass
npmod = types.ModuleType('numpy')
npmod.bool_ = _NoMatch; npmod.integer = _NoMatch; npmod.floating = _NoMatch; npmod.ndarray = _NoMatch
sys.modules.setdefault('numpy', npmod)

try:
    import pyproj  # noqa
except ImportError:
    class _FakeTransformer:
        def __init__(self, kind): self._kind = kind
        @classmethod
        def from_crs(cls, src, dst, always_xy=True): return cls('x')
        @classmethod
        def from_pipeline(cls, pipeline): return cls('x')
        def transform(self, *a): return (0.0, 0.0, 0.0)
    pyproj_mod = types.ModuleType('pyproj')
    pyproj_mod.Transformer = _FakeTransformer
    sys.modules['pyproj'] = pyproj_mod

try:
    from addons.features.auto_survey import survey_controller as mod
except Exception as e:
    print("IMPORT_FAILED", repr(e))
    sys.exit(0)

class FakeState:
    def __init__(self):
        self.owned = False
    def get_file_service_owned(self):
        return self.owned
    def set_file_service_owned(self, v):
        self.owned = v

class FakeController:
    pass

ctrl = FakeController()
ctrl.state = FakeState()
ctrl._ensure_file_logging = mod.SurveyController._ensure_file_logging.__get__(ctrl)
ctrl._stop_file_logging = mod.SurveyController._stop_file_logging.__get__(ctrl)
ctrl._file_logging_enabled_by_user = mod.SurveyController._file_logging_enabled_by_user.__get__(ctrl)

import logging
logging.getLogger().addHandler(logging.NullHandler())
mod.logger = logging.getLogger("test")

state_file = os.environ["GM_TEST_STATE_FILE"]

print("ENSURE_RESULT", ctrl._ensure_file_logging())
print("OWNED_AFTER_ENSURE", ctrl.state.owned)
with open(state_file) as f:
    print("STATE_AFTER_ENSURE", f.read().strip())

# Simulate the user enabling+starting the service mid-survey (the UI
# toggle's own ServiceController.start() -> EnableUnitFiles + Start).
with open(state_file, "w") as f:
    f.write("active,enabled")
print("STATE_MID_SURVEY_USER_ENABLE", "active,enabled")

print("STOP_RESULT", ctrl._stop_file_logging(reason="test"))
print("OWNED_AFTER_STOP", ctrl.state.owned)
with open(state_file) as f:
    print("STATE_AFTER_STOP", f.read().strip())
PYEOF
}

echo "== Case A: service starts disabled+inactive (never enabled by the user) =="
echo "inactive,disabled" > "$W/state_a"
OUT=$(run_py "$W/state_a")
echo "$OUT"
if echo "$OUT" | grep -q "^IMPORT_FAILED"; then
  echo "SKIP: survey_controller.py could not be imported in isolation in this environment"
  exit 0
fi
echo "$OUT" | grep -q "^ENSURE_RESULT True" && ok "Case A: _ensure_file_logging() succeeds" || bad "Case A: _ensure_file_logging() failed"
echo "$OUT" | grep -q "^OWNED_AFTER_ENSURE True" && ok "Case A: survey takes ownership (started it itself)" || bad "Case A: ownership not taken"
echo "$OUT" | grep -q "^STATE_AFTER_ENSURE active,disabled" && ok "Case A: service is active but NOT enabled after start (plain systemctl start, no EnableUnitFiles)" || bad "Case A: service state wrong after start"
echo "$OUT" | grep -q "^STOP_RESULT True" && ok "Case A: _stop_file_logging() succeeds" || bad "Case A: _stop_file_logging() failed"
echo "$OUT" | grep -q "^OWNED_AFTER_STOP False" && ok "Case A: ownership released after stop" || bad "Case A: ownership not released"
echo "$OUT" | grep -q "^STATE_AFTER_STOP inactive,disabled" && ok "Case A: service is inactive and STILL not-enabled after stop (plain systemctl stop, no DisableUnitFiles - was already disabled, stop must not change that either way)" || bad "Case A: service state wrong after stop"

echo "== Case B: service already enabled+active before the survey - the survey owns it anyway (survey-only policy) =="
echo "active,enabled" > "$W/state_b"
OUT=$(run_py "$W/state_b")
echo "$OUT"
echo "$OUT" | grep -q "^OWNED_AFTER_ENSURE True" && ok "Case B: survey claims ownership (survey-only policy)" || bad "Case B: survey did not claim ownership"
echo "$OUT" | grep -q "^STATE_AFTER_ENSURE active,enabled" && ok "Case B: service state unchanged after ensure (already active+enabled)" || bad "Case B: service state changed after ensure"
echo "$OUT" | grep -q "^STOP_RESULT True" && ok "Case B: _stop_file_logging() succeeds" || bad "Case B: _stop_file_logging() failed"
echo "$OUT" | grep -q "^OWNED_AFTER_STOP False" && ok "Case B: ownership released after stop" || bad "Case B: ownership not released"
echo "$OUT" | grep -q "^STATE_AFTER_STOP inactive,enabled" && ok "Case B: service stopped but enabled flag untouched (stop never disables)" || bad "Case B: service state wrong after stop"

echo "== Case C: survey claims ownership (service was off), user enables+starts it MID-SURVEY, survey ends - survey stops it anyway (survey-only policy) =="
echo "inactive,disabled" > "$W/state_c"
OUT=$(run_py_mid_survey_enable "$W/state_c")
echo "$OUT"
echo "$OUT" | grep -q "^OWNED_AFTER_ENSURE True" && ok "Case C: survey takes ownership initially (service was off)" || bad "Case C: ownership not taken initially"
echo "$OUT" | grep -q "^STOP_RESULT True" && ok "Case C: _stop_file_logging() succeeds" || bad "Case C: _stop_file_logging() failed"
echo "$OUT" | grep -q "^OWNED_AFTER_STOP False" && ok "Case C: ownership released after stop" || bad "Case C: ownership not released"
echo "$OUT" | grep -q "^STATE_AFTER_STOP inactive,enabled" && ok "Case C: service stopped at survey end regardless of mid-survey user-enable (survey-only policy)" || bad "Case C: service state wrong after stop"

run_py_stop_without_ownership() {
  GM_TEST_STATE_FILE="$1" "$PYTHON" - "$REPO" << 'PYEOF'
import sys, types, os

repo = sys.argv[1]
sys.path.insert(0, repo)

class _Any:
    def __init__(self, *a, **k): pass
    def __call__(self, *a, **k): return _Any()
    def __getattr__(self, n): return _Any()
for name in ('flask', 'flask_login', 'serial', 'scipy', 'scipy.stats', 'requests'):
    m = types.ModuleType(name)
    m.__getattr__ = lambda n: _Any()
    sys.modules.setdefault(name, m)

class _NoMatch: pass
npmod = types.ModuleType('numpy')
npmod.bool_ = _NoMatch; npmod.integer = _NoMatch; npmod.floating = _NoMatch; npmod.ndarray = _NoMatch
sys.modules.setdefault('numpy', npmod)

try:
    import pyproj  # noqa
except ImportError:
    class _FakeTransformer:
        def __init__(self, kind): self._kind = kind
        @classmethod
        def from_crs(cls, src, dst, always_xy=True): return cls('x')
        @classmethod
        def from_pipeline(cls, pipeline): return cls('x')
        def transform(self, *a): return (0.0, 0.0, 0.0)
    pyproj_mod = types.ModuleType('pyproj')
    pyproj_mod.Transformer = _FakeTransformer
    sys.modules['pyproj'] = pyproj_mod

try:
    from addons.features.auto_survey import survey_controller as mod
except Exception as e:
    print("IMPORT_FAILED", repr(e))
    sys.exit(0)

class FakeState:
    def __init__(self):
        self.owned = False
    def get_file_service_owned(self):
        return self.owned
    def set_file_service_owned(self, v):
        self.owned = v

class FakeController:
    pass

ctrl = FakeController()
ctrl.state = FakeState()
ctrl._stop_file_logging = mod.SurveyController._stop_file_logging.__get__(ctrl)

import logging
logging.getLogger().addHandler(logging.NullHandler())
mod.logger = logging.getLogger("test")

state_file = os.environ["GM_TEST_STATE_FILE"]

print("STOP_RESULT", ctrl._stop_file_logging(reason="test"))
with open(state_file) as f:
    print("STATE_AFTER_STOP", f.read().strip())
PYEOF
}

echo "== Case D: service active+enabled but ownership flag lost (stale latch) - survey still stops it =="
echo "active,enabled" > "$W/state_d"
OUT=$(run_py_stop_without_ownership "$W/state_d")
echo "$OUT"
echo "$OUT" | grep -q "^STOP_RESULT True" && ok "Case D: _stop_file_logging() succeeds even without ownership flag" || bad "Case D: _stop_file_logging() failed"
echo "$OUT" | grep -q "^STATE_AFTER_STOP inactive,enabled" && ok "Case D: service stopped at survey end even if ownership flag was lost" || bad "Case D: service state wrong after stop"

echo "== Case E: StateManager file_service_started_at timestamp lifecycle =="
STATE_FILE_E="$W/state_e.json"
OUT=$("$PYTHON" - "$REPO" "$STATE_FILE_E" << 'PYEOF'
import sys, types, os, json, datetime

repo = sys.argv[1]
state_file = sys.argv[2]
sys.path.insert(0, repo)

class _Any:
    def __init__(self, *a, **k): pass
    def __call__(self, *a, **k): return _Any()
    def __getattr__(self, n): return _Any()
for name in ('flask', 'flask_login', 'serial', 'scipy', 'scipy.stats', 'requests'):
    m = types.ModuleType(name)
    m.__getattr__ = lambda n: _Any()
    sys.modules.setdefault(name, m)

class _NoMatch: pass
npmod = types.ModuleType('numpy')
npmod.bool_ = _NoMatch; npmod.integer = _NoMatch; npmod.floating = _NoMatch; npmod.ndarray = _NoMatch
sys.modules.setdefault('numpy', npmod)

try:
    import pyproj  # noqa
except ImportError:
    class _FakeTransformer:
        def __init__(self, kind): self._kind = kind
        @classmethod
        def from_crs(cls, src, dst, always_xy=True): return cls('x')
        @classmethod
        def from_pipeline(cls, pipeline): return cls('x')
        def transform(self, *a): return (0.0, 0.0, 0.0)
    pyproj_mod = types.ModuleType('pyproj')
    pyproj_mod.Transformer = _FakeTransformer
    sys.modules['pyproj'] = pyproj_mod

try:
    from addons.features.auto_survey.state_manager import StateManager
except Exception as e:
    print("IMPORT_FAILED", repr(e))
    sys.exit(0)

sm = StateManager(state_file=state_file)
started = sm.get_status()['file_service_started_at']
print("STARTED_INITIAL", started)

sm.set_file_service_owned(True)
started = sm.get_status()['file_service_started_at']
print("STARTED_AFTER_SET", started)
try:
    datetime.datetime.fromisoformat(started)
    print("PARSE_OK")
except Exception as e:
    print("PARSE_FAILED", repr(e))

sm.set_file_service_owned(False)
started = sm.get_status()['file_service_started_at']
print("STARTED_AFTER_CLEAR", started)
PYEOF
)
echo "$OUT"
echo "$OUT" | grep -q "^STARTED_INITIAL None" && ok "Case E: file_service_started_at is None initially" || bad "Case E: initial timestamp not None"
echo "$OUT" | grep -q "^STARTED_AFTER_SET [0-9]" && ok "Case E: timestamp set after set_file_service_owned(True)" || bad "Case E: timestamp not set"
echo "$OUT" | grep -q "^PARSE_OK" && ok "Case E: timestamp is valid ISO format" || bad "Case E: timestamp not parseable"
echo "$OUT" | grep -q "^STARTED_AFTER_CLEAR None" && ok "Case E: timestamp cleared after set_file_service_owned(False)" || bad "Case E: timestamp not cleared"

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
