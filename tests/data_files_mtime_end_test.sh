#!/usr/bin/env bash
set -uo pipefail

REPO="${GM_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not available"
    exit 0
fi

python3 - "$REPO" <<'PYEOF'
import sys, os, tempfile, importlib.util, types, calendar
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

def make_file(root, ts, mtime=None):
    name = ts.strftime('%Y-%m-%d_%H-%M-%S') + '_GNSS-1.ubx'
    path = root / 'data' / name
    path.write_bytes(b'')
    if mtime is not None:
        ts = calendar.timegm(mtime.timetuple())
        os.utime(path, (ts, ts))
    return name

def get_names(files):
    return sorted([f.name for f in files])

def run_case(name, fn):
    try:
        fn()
    except Exception as e:
        bad(f"{name}: {e}")

now = datetime.utcnow().replace(microsecond=0)
start = now - timedelta(minutes=30)

def case_a():
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg = make_config(root)
        old_name = make_file(root, start - timedelta(hours=3), mtime=start - timedelta(minutes=2))
        new_name = make_file(root, start + timedelta(seconds=20), mtime=now)
        files = cfg.get_data_files_since(start)
        names = get_names(files)
        expected = [new_name]
        if names == expected:
            ok("A: old file with recent mtime excluded")
        else:
            bad(f"A: expected {expected}, got {names}")

def case_b():
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg = make_config(root)
        active_name = make_file(root, start - timedelta(hours=6), mtime=now)
        new_name = make_file(root, start + timedelta(minutes=10), mtime=now)
        files = cfg.get_data_files_since(start)
        names = get_names(files)
        expected = sorted([active_name, new_name])
        if names == expected:
            ok("B: active file with old name included")
        else:
            bad(f"B: expected {expected}, got {names}")

def case_c():
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg = make_config(root)
        ended_name = make_file(root, start - timedelta(hours=3), mtime=start + timedelta(minutes=5))
        new_name = make_file(root, start + timedelta(minutes=10), mtime=now)
        files = cfg.get_data_files_since(start)
        names = get_names(files)
        expected = sorted([ended_name, new_name])
        if names == expected:
            ok("C: file ending in window included")
        else:
            bad(f"C: expected {expected}, got {names}")

def case_d():
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg = make_config(root)
        old_name = make_file(root, start - timedelta(hours=1), mtime=start - timedelta(minutes=10))
        files = cfg.get_data_files_since(start)
        if len(files) == 0:
            ok("D: file ending before window excluded")
        else:
            bad(f"D: expected [], got {get_names(files)}")

def case_e():
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg = make_config(root)
        boundary_name = make_file(root, start - timedelta(hours=3), mtime=start - timedelta(seconds=30))
        new_name = make_file(root, start + timedelta(seconds=20), mtime=now)
        files = cfg.get_data_files_since(start)
        names = get_names(files)
        expected = sorted([boundary_name, new_name])
        if names == expected:
            ok("E: mtime within 60s tolerance included")
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
