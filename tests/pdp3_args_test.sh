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
import importlib.util
import math

REPO = sys.argv[1]

# Load the real module
module_path = os.environ.get('GM_PDP3_MODULE')
if not module_path:
    module_path = os.path.join(REPO, 'addons', 'features', 'auto_survey', 'pride_pppar_processor' + '.py')

spec = importlib.util.spec_from_file_location('pride_pppar_processor', module_path)
mod = importlib.util.module_from_spec(spec)
sys.modules['pride_pppar_processor'] = mod
spec.loader.exec_module(mod)

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

freq = {'frq': ['G12', 'R12', 'E17'], 'sys': 'GRE'}

# Case A: Default call
try:
    result = mod.build_pdp3_args('/x/pdp3', freq, 'obs.26o')
    expected = ['/x/pdp3', '-m', 'S', '-frq', 'G12', 'R12', 'E17', '-sys', 'GRE', '-i', '30', 'obs.26o']
    if result == expected:
        ok("A: default call produces correct args")
    else:
        bad(f"A: default call mismatch: {result}")
except Exception as e:
    bad(f"A: exception: {e}")

# Case B: freq['sys'] is None
try:
    freq_no_sys = {'frq': ['G12', 'R12', 'E17'], 'sys': None}
    result = mod.build_pdp3_args('/x/pdp3', freq_no_sys, 'obs.26o')
    if '-sys' not in result and '-i' in result and result[-1] == 'obs.26o':
        ok("B: no -sys when sys is None")
    else:
        bad(f"B: unexpected result: {result}")
except Exception as e:
    bad(f"B: exception: {e}")

# Case C: sample_interval=None
try:
    result = mod.build_pdp3_args('/x/pdp3', freq, 'obs.26o', sample_interval=None)
    if '-i' not in result and result[-1] == 'obs.26o':
        ok("C: no -i when sample_interval is None")
    else:
        bad(f"C: unexpected result: {result}")
except Exception as e:
    bad(f"C: exception: {e}")

# Case D: sample_interval=0.5
try:
    result = mod.build_pdp3_args('/x/pdp3', freq, 'obs.26o', sample_interval=0.5)
    if '-i' in result and '0.5' in result:
        ok("D: -i 0.5 present")
    else:
        bad(f"D: unexpected result: {result}")
except Exception as e:
    bad(f"D: exception: {e}")

# Case E: invalid sample_interval values
for val, label in [(0, 'zero'), (-1, 'negative'), (301, 'too large'), (float('nan'), 'nan'), (float('inf'), 'inf')]:
    try:
        mod.build_pdp3_args('/x/pdp3', freq, 'obs.26o', sample_interval=val)
        bad(f"E: {label} did not raise ValueError")
    except ValueError:
        ok(f"E: {label} raises ValueError")
    except Exception as e:
        bad(f"E: {label} raised wrong exception: {e}")

# Case F: constant value
try:
    if mod.PPP_AR_SAMPLE_INTERVAL_S == 30.0:
        ok("F: PPP_AR_SAMPLE_INTERVAL_S is 30.0")
    else:
        bad(f"F: PPP_AR_SAMPLE_INTERVAL_S is {mod.PPP_AR_SAMPLE_INTERVAL_S}")
except Exception as e:
    bad(f"F: exception: {e}")

# Case G: real code path - check source text
try:
    with open(module_path, 'r') as f:
        source = f.read()
    if 'build_pdp3_args(self.pdp3, freq, local_obs_file.name)' in source:
        ok("G: process_ppp_ar calls build_pdp3_args")
    else:
        bad("G: process_ppp_ar does not call build_pdp3_args")
    if 'pdp3_args = [str(self.pdp3), "-m", "S"' not in source:
        ok("G: old inline pdp3_args construction removed")
    else:
        bad("G: old inline pdp3_args construction still present")
except Exception as e:
    bad(f"G: exception: {e}")

print(f"RESULT: {PASS} passed, {FAIL} failed")
sys.exit(FAIL)
PYEOF

exit $?
