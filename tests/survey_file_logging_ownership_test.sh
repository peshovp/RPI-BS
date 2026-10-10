#!/usr/bin/env bash
# Unit-style test for survey_controller.py's one-owner rule
# (_ensure_file_logging()/_stop_file_logging()) - 2026-10-07 review:
# exhaustively confirmed, by reading the code and by git history search
# (git log -S"disable"/-S"DisableUnitFiles" across every relevant file,
# since before the 2026-10-01 incident), that this code path calls PLAIN
# `systemctl start`/`systemctl stop` via subprocess.run - NEVER
# ServiceController's pystemd wrapper (whose own stop() ALSO calls
# DisableUnitFiles, by upstream design, for the UI's own on/off toggle -
# see web_app/ServiceController.py). This test proves that a survey's
# own start/stop cycle preserves str2str_file.service's enabled state
# exactly (start does not enable; stop does not disable) - the actual,
# confirmed root cause of the 2026-10-01 incident (d8e817a's stale
# file_service_owned bug) was entirely about WHEN stop was called, never
# about stop disabling anything it shouldn't have.
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

# GeoMaxima - 2026-10-10 review follow-up: Case C below - the survey
# claims ownership (service was off), then the USER enables+starts the
# service mid-survey via the UI toggle (simulated here by mutating the
# state file directly between _ensure_file_logging() and
# _stop_file_logging(), standing in for switchService() running in
# between), then the survey ends. Hand-back must leave the service
# active+enabled - _stop_file_logging()'s own is-enabled re-check
# (survey_controller.py's _file_logging_enabled_by_user(), called again
# immediately before stopping) is the mechanism this test actually
# exercises, not a new code path.
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

echo "== Case B: service was already enabled+active by the user BEFORE the survey - survey must never claim ownership or touch it =="
echo "active,enabled" > "$W/state_b"
OUT=$(run_py "$W/state_b")
echo "$OUT"
echo "$OUT" | grep -q "^OWNED_AFTER_ENSURE False" && ok "Case B: survey does NOT claim ownership of a user-enabled service" || bad "Case B: survey wrongly claimed ownership"
echo "$OUT" | grep -q "^STATE_AFTER_ENSURE active,enabled" && ok "Case B: service state completely untouched after ensure (still active+enabled)" || bad "Case B: service state was changed after ensure"
echo "$OUT" | grep -q "^STATE_AFTER_STOP active,enabled" && ok "Case B: service state completely untouched after stop too (still active+enabled - never this survey's to stop)" || bad "Case B: service state was changed after stop"

echo "== Case C: survey claims ownership (service was off), user enables+starts it MID-SURVEY, survey ends - hand-back must leave it active+enabled =="
echo "inactive,disabled" > "$W/state_c"
OUT=$(run_py_mid_survey_enable "$W/state_c")
echo "$OUT"
echo "$OUT" | grep -q "^OWNED_AFTER_ENSURE True" && ok "Case C: survey takes ownership initially (service was off)" || bad "Case C: ownership not taken initially"
echo "$OUT" | grep -q "^STOP_RESULT True" && ok "Case C: _stop_file_logging() succeeds" || bad "Case C: _stop_file_logging() failed"
echo "$OUT" | grep -q "^OWNED_AFTER_STOP False" && ok "Case C: ownership released (recognized the service is now user-managed)" || bad "Case C: ownership not released"
echo "$OUT" | grep -q "^STATE_AFTER_STOP active,enabled" && ok "Case C: service left active+enabled after hand-back (mid-survey user-enable preserved, not stopped)" || bad "Case C: service state wrong after hand-back - mid-survey enable was NOT preserved"

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
