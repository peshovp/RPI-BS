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
import importlib.util
from pathlib import Path

REPO = sys.argv[1]

# Load the real module without importing the package
converter_path = os.environ.get('GM_RINEX_CONVERTER')
if not converter_path:
    converter_path = os.path.join(REPO, 'addons', 'features', 'auto_survey', 'rinex_converter.py')

spec = importlib.util.spec_from_file_location("rinex_converter", converter_path)
rc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rc)

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

def make_empty_file(path):
    with open(path, 'w') as f:
        f.write('')

with tempfile.TemporaryDirectory() as tmpdir:
    tmp = Path(tmpdir)

    # Case A: One raw file with time window
    try:
        raw_a = tmp / 'single.ubx'
        make_empty_file(raw_a)
        calls_a = []
        def recorder_a(raw_file, output_dir, **kw):
            calls_a.append((raw_file, kw))
            os.makedirs(output_dir, exist_ok=True)
            out = Path(output_dir) / 'x.obs'
            out.write_text('')
            return (out, None)
        conv_a = rc.RINEXConverter.__new__(rc.RINEXConverter)
        conv_a.convert_raw_to_rinex_obs = recorder_a
        result_a = conv_a.convert_raw_files_to_rinex_obs([raw_a], tmp / 'out_a', time_start='2026-10-01 00:00:00', time_end='2026-10-01 23:59:59')
        if len(calls_a) == 1:
            ok("A: exactly one convert call")
        else:
            bad(f"A: expected 1 call, got {len(calls_a)}")
        if calls_a:
            kw = calls_a[0][1]
            if kw.get('time_start') == '2026-10-01 00:00:00':
                ok("A: time_start forwarded")
            else:
                bad(f"A: time_start not forwarded (got {kw.get('time_start')})")
            if kw.get('time_end') == '2026-10-01 23:59:59':
                ok("A: time_end forwarded")
            else:
                bad(f"A: time_end not forwarded (got {kw.get('time_end')})")
    except Exception as e:
        bad(f"A: exception: {e}")

    # Case B: Three raw files with time window
    try:
        raw_b1 = tmp / '2026-10-01_00-00-00_GNSS-1.ubx'
        raw_b2 = tmp / '2026-10-02_00-00-00_GNSS-1.ubx'
        raw_b3 = tmp / '2026-10-03_00-00-00_GNSS-1.ubx'
        make_empty_file(raw_b1)
        make_empty_file(raw_b2)
        make_empty_file(raw_b3)
        calls_b = []
        def recorder_b(raw_file, output_dir, **kw):
            calls_b.append((raw_file, kw))
            os.makedirs(output_dir, exist_ok=True)
            out = Path(output_dir) / 'x.obs'
            out.write_text('')
            return (out, None)
        def merge_stub(obs_files, output_path):
            output_path.write_text('')
            return output_path
        conv_b = rc.RINEXConverter.__new__(rc.RINEXConverter)
        conv_b.convert_raw_to_rinex_obs = recorder_b
        orig_merge = rc.merge_rinex_obs
        rc.merge_rinex_obs = merge_stub
        result_b = conv_b.convert_raw_files_to_rinex_obs([raw_b1, raw_b2, raw_b3], tmp / 'out_b', time_start='2026-10-01 00:00:00', time_end='2026-10-03 23:59:59')
        rc.merge_rinex_obs = orig_merge
        if len(calls_b) == 3:
            ok("B: three convert calls")
        else:
            bad(f"B: expected 3 calls, got {len(calls_b)}")
        all_have_window = all(
            kw.get('time_start') == '2026-10-01 00:00:00' and kw.get('time_end') == '2026-10-03 23:59:59'
            for _, kw in calls_b
        )
        if all_have_window:
            ok("B: all calls have time window")
        else:
            bad("B: not all calls have time window")
    except Exception as e:
        bad(f"B: exception: {e}")

    # Case C: Three raw files without time window
    try:
        calls_c = []
        def recorder_c(raw_file, output_dir, **kw):
            calls_c.append((raw_file, kw))
            os.makedirs(output_dir, exist_ok=True)
            out = Path(output_dir) / 'x.obs'
            out.write_text('')
            return (out, None)
        def merge_stub_c(obs_files, output_path):
            output_path.write_text('')
            return output_path
        conv_c = rc.RINEXConverter.__new__(rc.RINEXConverter)
        conv_c.convert_raw_to_rinex_obs = recorder_c
        orig_merge_c = rc.merge_rinex_obs
        rc.merge_rinex_obs = merge_stub_c
        result_c = conv_c.convert_raw_files_to_rinex_obs([raw_b1, raw_b2, raw_b3], tmp / 'out_c')
        rc.merge_rinex_obs = orig_merge_c
        if len(calls_c) == 3:
            ok("C: three convert calls without window")
        else:
            bad(f"C: expected 3 calls, got {len(calls_c)}")
        all_none = all(
            kw.get('time_start') is None and kw.get('time_end') is None
            for _, kw in calls_c
        )
        if all_none:
            ok("C: all calls have no time window")
        else:
            bad("C: some calls have unexpected time window")
    except Exception as e:
        bad(f"C: exception: {e}")

    # Case D: Only time_start given
    try:
        calls_d = []
        def recorder_d(raw_file, output_dir, **kw):
            calls_d.append((raw_file, kw))
            os.makedirs(output_dir, exist_ok=True)
            out = Path(output_dir) / 'x.obs'
            out.write_text('')
            return (out, None)
        def merge_stub_d(obs_files, output_path):
            output_path.write_text('')
            return output_path
        conv_d = rc.RINEXConverter.__new__(rc.RINEXConverter)
        conv_d.convert_raw_to_rinex_obs = recorder_d
        orig_merge_d = rc.merge_rinex_obs
        rc.merge_rinex_obs = merge_stub_d
        result_d = conv_d.convert_raw_files_to_rinex_obs([raw_b1, raw_b2, raw_b3], tmp / 'out_d', time_start='2026-10-01 00:00:00')
        rc.merge_rinex_obs = orig_merge_d
        if len(calls_d) == 3:
            ok("D: three convert calls with only time_start")
        else:
            bad(f"D: expected 3 calls, got {len(calls_d)}")
        all_start = all(
            kw.get('time_start') == '2026-10-01 00:00:00' and kw.get('time_end') is None
            for _, kw in calls_d
        )
        if all_start:
            ok("D: all calls have time_start only")
        else:
            bad("D: not all calls have correct time_start only")
    except Exception as e:
        bad(f"D: exception: {e}")

print(f"RESULT: {PASS} passed, {FAIL} failed")
sys.exit(FAIL)
PYEOF

exit $?
