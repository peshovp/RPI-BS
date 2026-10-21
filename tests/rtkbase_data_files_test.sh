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
import tempfile
import logging
import importlib.util
import types
import zipfile
from pathlib import Path
from datetime import datetime, timedelta

REPO = sys.argv[1]

# Load the real modules without importing the package
DIR = os.environ.get('GM_AUTOSURVEY_DIR')
if not DIR:
    DIR = os.path.join(REPO, 'addons', 'features', 'auto_survey')

pkg = types.ModuleType('gm_autosurvey_pkg')
pkg.__path__ = [DIR]
sys.modules['gm_autosurvey_pkg'] = pkg

for name in ('rinex_converter', 'rtkbase_config'):
    spec = importlib.util.spec_from_file_location(
        'gm_autosurvey_pkg.' + name,
        os.path.join(DIR, name + '.py')
    )
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

def seg_name(dt):
    return f"{dt:%Y-%m-%d_%H-%M-%S}_GNSS-1.ubx"

def make_plain_segment(data_dir, dt):
    path = data_dir / seg_name(dt)
    path.write_bytes(b'\x00' * 100)
    return path

def make_zip_segment(data_dir, dt, zip_name=None):
    if zip_name is None:
        zip_name = f"archive_{dt:%Y%m%d}.zip"
    zip_path = data_dir / zip_name
    member_name = seg_name(dt)
    with zipfile.ZipFile(zip_path, 'w') as zf:
        zf.writestr(member_name, b'\x00' * 100)
    return zip_path, member_name

def make_config(root, rotate='24', overlap='0'):
    settings = root / 'settings.conf'
    settings.write_text(f"[local_storage]\nfile_rotate_time='{rotate}'\nfile_overlap_time='{overlap}'\n")
    data_dir = root / 'data'
    data_dir.mkdir()
    return cfg_mod.RTKBaseConfig(settings_file=str(settings)), data_dir

def run_case(name, fn):
    try:
        fn()
    except Exception as e:
        bad(f"{name}: {e}")

now = datetime.utcnow().replace(microsecond=0)
start = now - timedelta(hours=2)

# Case A: THE LIVE BUG
def case_a():
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg, data_dir = make_config(root)
        old_seg = start - timedelta(days=6)
        make_zip_segment(data_dir, old_seg)
        new_seg = start + timedelta(seconds=19)
        make_plain_segment(data_dir, new_seg)
        extract_dir = root / 'extract'
        result = cfg.get_data_files_since(start, extract_dir)
        result_names = [p.name for p in result]
        expected = [seg_name(new_seg)]
        if result_names == expected:
            ok("A: only current segment returned (live bug fixed)")
        else:
            bad(f"A: wrong segments returned: {result_names}")
        if not extract_dir.exists() or not any(extract_dir.iterdir()):
            ok("A: no files extracted from old zip")
        else:
            bad("A: old zip was extracted")

run_case("A", case_a)

# Case B: Segment active at survey start
def case_b():
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg, data_dir = make_config(root)
        seg1 = start - timedelta(hours=6)
        seg2 = start + timedelta(hours=1)
        make_plain_segment(data_dir, seg1)
        make_plain_segment(data_dir, seg2)
        result = cfg.get_data_files_since(start)
        result_names = sorted([p.name for p in result])
        expected = sorted([seg_name(seg1), seg_name(seg2)])
        if result_names == expected:
            ok("B: both segments returned (active at start)")
        else:
            bad(f"B: wrong segments: {result_names}")

run_case("B", case_b)

# Case C: Rotation inside window
def case_c():
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg, data_dir = make_config(root)
        seg1 = start - timedelta(hours=30)
        seg2 = start - timedelta(hours=5)
        seg3 = start + timedelta(hours=1)
        make_plain_segment(data_dir, seg1)
        make_plain_segment(data_dir, seg2)
        make_plain_segment(data_dir, seg3)
        result = cfg.get_data_files_since(start)
        result_names = sorted([p.name for p in result])
        expected = sorted([seg_name(seg2), seg_name(seg3)])
        if result_names == expected:
            ok("C: old segment excluded, recent ones included")
        else:
            bad(f"C: wrong segments: {result_names}")

run_case("C", case_c)

# Case D: Legitimately archived member
def case_d():
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg, data_dir = make_config(root)
        old_seg = start - timedelta(hours=4)
        zip_path, member_name = make_zip_segment(data_dir, old_seg)
        new_seg = start + timedelta(hours=1)
        make_plain_segment(data_dir, new_seg)
        extract_dir = root / 'extract'
        result = cfg.get_data_files_since(start, extract_dir)
        result_names = [p.name for p in result]
        if member_name in result_names and seg_name(new_seg) in result_names:
            ok("D: archived member and current segment both returned")
        else:
            bad(f"D: wrong segments: {result_names}")
        extracted = extract_dir / member_name
        if extracted.exists():
            ok("D: zip member was extracted")
        else:
            bad("D: zip member not extracted")

run_case("D", case_d)

# Case E: Configured rotation honoured
def case_e():
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg, data_dir = make_config(root, rotate='72')
        old_seg = start - timedelta(hours=48)
        new_seg = start + timedelta(hours=1)
        make_plain_segment(data_dir, old_seg)
        make_plain_segment(data_dir, new_seg)
        result = cfg.get_data_files_since(start)
        result_names = [p.name for p in result]
        if seg_name(old_seg) in result_names:
            ok("E: 72h rotation includes 48h-old segment")
        else:
            bad("E: 72h rotation excluded 48h-old segment")
    
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg, data_dir = make_config(root, rotate='24')
        old_seg = start - timedelta(hours=48)
        new_seg = start + timedelta(hours=1)
        make_plain_segment(data_dir, old_seg)
        make_plain_segment(data_dir, new_seg)
        result = cfg.get_data_files_since(start)
        result_names = [p.name for p in result]
        if seg_name(old_seg) not in result_names:
            ok("E: 24h rotation excludes 48h-old segment")
        else:
            bad("E: 24h rotation included 48h-old segment")
    
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        settings = root / 'settings.conf'
        settings.write_text("[local_storage]\nfile_rotate_time=72\nfile_overlap_time=0\n")
        data_dir = root / 'data'
        data_dir.mkdir()
        cfg = cfg_mod.RTKBaseConfig(settings_file=str(settings))
        old_seg = start - timedelta(hours=48)
        new_seg = start + timedelta(hours=1)
        make_plain_segment(data_dir, old_seg)
        make_plain_segment(data_dir, new_seg)
        result = cfg.get_data_files_since(start)
        result_names = [p.name for p in result]
        if seg_name(old_seg) in result_names:
            ok("E: unquoted 72 rotation works")
        else:
            bad("E: unquoted 72 rotation failed")

run_case("E", case_e)

# Case F: Invalid values fall back
def case_f():
    invalid_rotates = ['abc', 'inf', 'nan', '-5', '0', '1e400', '99999', '']
    for rot in invalid_rotates:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            cfg, _ = make_config(root, rotate=rot, overlap='0')
            try:
                result = cfg._max_segment_seconds()
                if result == 24 * 3600 + 120:
                    ok(f"F: invalid rotate '{rot}' falls back to 24h")
                else:
                    bad(f"F: invalid rotate '{rot}' gave {result}")
            except Exception as e:
                bad(f"F: invalid rotate '{rot}' raised: {e}")
    
    invalid_overlaps = ['x', 'inf', '-1', '1e400']
    for ov in invalid_overlaps:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            cfg, _ = make_config(root, rotate='24', overlap=ov)
            try:
                result = cfg._max_segment_seconds()
                if result == 24 * 3600 + 120:
                    ok(f"F: invalid overlap '{ov}' falls back")
                else:
                    bad(f"F: invalid overlap '{ov}' gave {result}")
            except Exception as e:
                bad(f"F: invalid overlap '{ov}' raised: {e}")

run_case("F", case_f)

# Case G: Arithmetic
def case_g():
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg, _ = make_config(root, rotate='24', overlap='0')
        result = cfg._max_segment_seconds()
        if result == 86520.0:
            ok("G: 24h rotation arithmetic correct")
        else:
            bad(f"G: expected 86520.0, got {result}")
    
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg, _ = make_config(root, rotate='1.5', overlap='60')
        result = cfg._max_segment_seconds()
        expected = 1.5 * 3600 + 60 + 120
        if result == expected:
            ok("G: 1.5h rotation + 60s overlap arithmetic correct")
        else:
            bad(f"G: expected {expected}, got {result}")

run_case("G", case_g)

# Case H: Undated file
def case_h():
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg, data_dir = make_config(root)
        unnamed = data_dir / 'unnamed.ubx'
        unnamed.write_bytes(b'\x00' * 100)
        current = start + timedelta(hours=1)
        make_plain_segment(data_dir, current)
        result = cfg.get_data_files_since(start)
        result_names = [p.name for p in result]
        if 'unnamed.ubx' in result_names and seg_name(current) in result_names:
            ok("H: undated file included (fail-open)")
        else:
            bad(f"H: wrong segments: {result_names}")

run_case("H", case_h)

# Case I: Nothing overlaps
def case_i():
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg, data_dir = make_config(root)
        old_seg = start - timedelta(days=6)
        make_zip_segment(data_dir, old_seg)
        result = cfg.get_data_files_since(start)
        if result == []:
            ok("I: no overlapping segments returns empty list")
        else:
            bad(f"I: expected empty, got {len(result)} segments")

run_case("I", case_i)

# Case J: Missing data directory
def case_j():
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg, data_dir = make_config(root)
        import shutil
        shutil.rmtree(data_dir)
        result = cfg.get_data_files_since(start)
        if result == []:
            ok("J: missing data directory returns empty list")
        else:
            bad(f"J: expected empty, got {len(result)} segments")

run_case("J", case_j)

# Case K: Log flooding guard
def case_k():
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        cfg, data_dir = make_config(root)
        excluded_names = []
        for i in range(7):
            old_seg = start - timedelta(days=10 - i)
            zip_path, member_name = make_zip_segment(data_dir, old_seg)
            excluded_names.append(member_name)
        current = start + timedelta(seconds=19)
        make_plain_segment(data_dir, current)
        
        logger = logging.getLogger('gm_autosurvey_pkg.rtkbase_config')
        old_level = logger.level
        logger.setLevel(logging.INFO)
        class TestHandler(logging.Handler):
            def __init__(self):
                super().__init__()
                self.messages = []
            def emit(self, record):
                self.messages.append(record.getMessage())
        handler = TestHandler()
        handler.setLevel(logging.INFO)
        logger.addHandler(handler)
        
        result = cfg.get_data_files_since(start)
        
        logger.removeHandler(handler)
        logger.setLevel(old_level)
        
        skipped_msgs = [m for m in handler.messages if 'skipped 7 segment(s)' in m]
        if len(skipped_msgs) != 1:
            bad(f"K: expected 1 skip message, got {len(skipped_msgs)}")
            return
        
        msg = skipped_msgs[0]
        if not msg.endswith(', ...'):
            bad("K: message doesn't end with ', ...'")
            return
        
        # Check that no other message names an individual excluded file
        other_msgs = [m for m in handler.messages if m != msg]
        for other in other_msgs:
            for name in excluded_names:
                if name in other:
                    bad(f"K: excluded file name {name} found in non-skip message")
                    return
        
        ok("K: log flooding guard works")

run_case("K", case_k)

print(f"RESULT: {PASS} passed, {FAIL} failed")
sys.exit(FAIL)
PYEOF

exit $?
