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
from datetime import datetime, timedelta

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

def make_config(root):
    settings = root / 'settings.conf'
    settings.write_text("[local_storage]\nfile_rotate_time='24'\nfile_overlap_time='0'\n")
    data_dir = root / 'data'
    data_dir.mkdir()
    return cfg_mod.RTKBaseConfig(settings_file=str(settings))

def make_file(root, ts):
    name = ts.strftime('%Y-%m-%d_%H-%M-%S') + '_GNSS-1.ubx'
    path = root / 'data' / name
    path.write_bytes(b'')
    return name

def get_names(files):
    return sorted([f.name for f in files])

def run_case(name, fn):
    try:
        fn()
    except Exception as e:
        bad(f"{name}: {e}")

now = datetime.utcnow().replace(microsecond=0)
start = now - timedelta(hours=10)

def case_a():
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg = make_config(root)
        f1 = make_file(root, start + timedelta(hours=1))
        f2 = make_file(root, start + timedelta(hours=3))
        f3 = make_file(root, start + timedelta(hours=6))
        end_time = start + timedelta(hours=4)
        files = cfg.get_data_files_since(start, end_time=end_time)
        names = get_names(files)
        expected = sorted([f1, f2])
        if names == expected:
            ok("A: end_time filters out later files")
        else:
            bad(f"A: expected {expected}, got {names}")

def case_b():
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg = make_config(root)
        f1 = make_file(root, start + timedelta(hours=1))
        f2 = make_file(root, start + timedelta(hours=3))
        f3 = make_file(root, start + timedelta(hours=6))
        files = cfg.get_data_files_since(start)
        names = get_names(files)
        expected = sorted([f1, f2, f3])
        if names == expected:
            ok("B: end_time=None includes all")
        else:
            bad(f"B: expected {expected}, got {names}")

def case_c():
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg = make_config(root)
        f1 = make_file(root, start + timedelta(hours=1))
        f2 = make_file(root, start + timedelta(hours=3))
        f3 = make_file(root, start + timedelta(hours=6))
        end_time = start + timedelta(minutes=30)
        files = cfg.get_data_files_since(start, end_time=end_time)
        if len(files) == 0:
            ok("C: end_time before any files returns empty")
        else:
            bad(f"C: expected [], got {get_names(files)}")

def case_d():
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg = make_config(root)
        f1 = make_file(root, start - timedelta(hours=2))
        f2 = make_file(root, start + timedelta(hours=1))
        end_time = start + timedelta(hours=2)
        files = cfg.get_data_files_since(start, end_time=end_time)
        names = get_names(files)
        expected = sorted([f1, f2])
        if names == expected:
            ok("D: file before start and within window both included")
        else:
            bad(f"D: expected {expected}, got {names}")

def case_e():
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg = make_config(root)
        f1 = make_file(root, start + timedelta(hours=1))
        f2 = make_file(root, start + timedelta(hours=3))
        f3 = make_file(root, start + timedelta(hours=6))
        end_time = start + timedelta(hours=3)
        files = cfg.get_data_files_since(start, end_time=end_time)
        names = get_names(files)
        expected = sorted([f1, f2])
        if names == expected:
            ok("E: end_time at segment start is inclusive")
        else:
            bad(f"E: expected {expected}, got {names}")

run_case("A", case_a)
run_case("B", case_b)
run_case("C", case_c)
run_case("D", case_d)
run_case("E", case_e)

print(f"RESULT: {PASS} passed, {FAIL} failed")
sys.exit(FAIL)
PYEOF

exit $?
