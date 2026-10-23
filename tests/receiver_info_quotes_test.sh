#!/usr/bin/env bash
set -uo pipefail

REPO="${GM_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not available"
    exit 0
fi

python3 - "$REPO" <<'PYEOF'
import sys, os, tempfile, importlib.util, types
from pathlib import Path

REPO = sys.argv[1]
DIR = os.path.join(REPO, 'addons', 'features', 'auto_survey')

pkg = types.ModuleType('gm_autosurvey_pkg')
pkg.__path__ = [DIR]
sys.modules['gm_autosurvey_pkg'] = pkg

for name in ('rinex_converter', 'rtkbase_config'):
    spec = importlib.util.spec_from_file_location(
        'gm_autosurvey_pkg.' + name, os.path.join(DIR, name + '.py'))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)

cfg_mod = sys.modules['gm_autosurvey_pkg.rtkbase_config']

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

def make_config(root, content):
    settings = root / 'settings.conf'
    settings.write_text(content)
    return cfg_mod.RTKBaseConfig(settings_file=str(settings))

def run_case(name, fn):
    try:
        fn()
    except Exception as e:
        bad(f"{name}: {e}")

def case_a():
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg = make_config(root, "[main]\nreceiver='u-blox ZED-F9P'\nreceiver_firmware='HPG 1.50'\nreceiver_format='ubx'\nantenna_info='ADVNULLANTENNA'\n")
        info = cfg.get_receiver_info()
        expected = {'model': 'u-blox ZED-F9P', 'firmware': 'HPG 1.50', 'format': 'ubx', 'antenna': 'ADVNULLANTENNA'}
        if info == expected:
            ok("A: single quotes stripped")
        else:
            bad(f"A: got {info}")

def case_b():
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg = make_config(root, "[main]\nantenna_info = \" BEITIAN_BT-K700 NONE \"\n")
        info = cfg.get_receiver_info()
        if info['antenna'] == 'BEITIAN_BT-K700 NONE':
            ok("B: double quotes and spaces stripped")
        else:
            bad(f"B: got '{info['antenna']}'")

def case_c():
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg = make_config(root, "[main]\nantenna_info=NONE\n")
        info = cfg.get_receiver_info()
        if info['antenna'] == 'NONE':
            ok("C: unquoted value")
        else:
            bad(f"C: got '{info['antenna']}'")

def case_d():
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg = make_config(root, "[main]\n")
        info = cfg.get_receiver_info()
        expected = {'model': 'Unknown', 'format': 'ubx', 'firmware': '', 'antenna': ''}
        if info == expected:
            ok("D: missing keys default")
        else:
            bad(f"D: got {info}")

def case_e():
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg = make_config(root, "[main]\nantenna_info='A B'\n")
        info = cfg.get_receiver_info()
        if info['antenna'] == 'A B':
            ok("E: inner space preserved")
        else:
            bad(f"E: got '{info['antenna']}'")

run_case("A", case_a)
run_case("B", case_b)
run_case("C", case_c)
run_case("D", case_d)
run_case("E", case_e)

print(f"RESULT: {PASS} passed, {FAIL} failed")
sys.exit(FAIL)
PYEOF

exit $?
