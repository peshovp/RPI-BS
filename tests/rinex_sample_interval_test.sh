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
from datetime import datetime

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

    # Case A: No sample_interval -> no -ti flag
    try:
        args_a = rc.build_convbin_args(Path('convbin'), Path('x.ubx'), Path('out'), 'ubx')
        if '-ti' not in args_a:
            ok("A: no -ti flag without sample_interval")
        else:
            bad("A: unexpected -ti flag without sample_interval")
        if args_a[-1] == 'x.ubx':
            ok("A: raw file is last element")
        else:
            bad(f"A: raw file not last (got {args_a[-1]})")
    except Exception as e:
        bad(f"A: exception: {e}")

    # Case B: sample_interval=30.0 -> -ti 30 before raw file
    try:
        args_b = rc.build_convbin_args(Path('convbin'), Path('x.ubx'), Path('out'), 'ubx', sample_interval=30.0)
        if '-ti' in args_b:
            ti_idx = args_b.index('-ti')
            if ti_idx + 1 < len(args_b) and args_b[ti_idx + 1] == '30':
                ok("B: -ti 30 present")
            else:
                bad(f"B: -ti not followed by 30 (got {args_b[ti_idx + 1] if ti_idx + 1 < len(args_b) else 'MISSING'})")
        else:
            bad("B: -ti flag missing")
        if args_b[-1] == 'x.ubx':
            ok("B: raw file is last element")
        else:
            bad(f"B: raw file not last (got {args_b[-1]})")
    except Exception as e:
        bad(f"B: exception: {e}")

    # Case C: sample_interval with time window -> -ti after -te, before raw file
    try:
        ts = datetime(2026, 10, 1, 0, 0, 0)
        te = datetime(2026, 10, 1, 23, 59, 59)
        args_c = rc.build_convbin_args(Path('convbin'), Path('x.ubx'), Path('out'), 'ubx',
                                       time_start=ts, time_end=te, sample_interval=30.0)
        if '-ti' in args_c and '-te' in args_c:
            ti_idx = args_c.index('-ti')
            te_idx = args_c.index('-te')
            if ti_idx > te_idx:
                ok("C: -ti appears after -te")
            else:
                bad("C: -ti not after -te")
            if args_c[-1] == 'x.ubx':
                ok("C: raw file is last element")
            else:
                bad(f"C: raw file not last (got {args_c[-1]})")
        else:
            bad("C: missing -ti or -te flag")
    except Exception as e:
        bad(f"C: exception: {e}")

    # Case D: sample_interval=0.5 -> -ti 0.5
    try:
        args_d = rc.build_convbin_args(Path('convbin'), Path('x.ubx'), Path('out'), 'ubx', sample_interval=0.5)
        if '-ti' in args_d:
            ti_idx = args_d.index('-ti')
            if ti_idx + 1 < len(args_d) and args_d[ti_idx + 1] == '0.5':
                ok("D: -ti 0.5 present")
            else:
                bad(f"D: -ti not followed by 0.5 (got {args_d[ti_idx + 1] if ti_idx + 1 < len(args_d) else 'MISSING'})")
        else:
            bad("D: -ti flag missing")
    except Exception as e:
        bad(f"D: exception: {e}")

    # Case E: Invalid sample_interval values raise ValueError
    for val, label in [(0, '0'), (-1, '-1'), (float('nan'), 'nan'), (float('inf'), 'inf')]:
        try:
            rc.build_convbin_args(Path('convbin'), Path('x.ubx'), Path('out'), 'ubx', sample_interval=val)
            bad(f"E: sample_interval={label} did not raise ValueError")
        except ValueError:
            ok(f"E: sample_interval={label} raises ValueError")
        except Exception as e:
            bad(f"E: sample_interval={label} raised {type(e).__name__}: {e}")

    # Case F: Forwarding with recorder - single file
    try:
        raw_f = tmp / 'single.ubx'
        make_empty_file(raw_f)
        calls_f = []
        def recorder_f(raw_file, output_dir, **kw):
            calls_f.append((raw_file, kw))
            os.makedirs(output_dir, exist_ok=True)
            out = Path(output_dir) / 'x.obs'
            out.write_text('')
            return (out, None)
        conv_f = rc.RINEXConverter.__new__(rc.RINEXConverter)
        conv_f.convert_raw_to_rinex_obs = recorder_f
        result_f = conv_f.convert_raw_files_to_rinex_obs([raw_f], tmp / 'out_f', sample_interval=30)
        if len(calls_f) == 1:
            ok("F: one convert call with sample_interval")
        else:
            bad(f"F: expected 1 call, got {len(calls_f)}")
        if calls_f and calls_f[0][1].get('sample_interval') == 30:
            ok("F: sample_interval=30 forwarded")
        else:
            bad(f"F: sample_interval not forwarded (got {calls_f[0][1].get('sample_interval') if calls_f else 'no calls'})")
    except Exception as e:
        bad(f"F: exception: {e}")

    # Case F2: Forwarding with recorder - three files
    try:
        raw_f1 = tmp / '2026-10-01_00-00-00_GNSS-1.ubx'
        raw_f2 = tmp / '2026-10-02_00-00-00_GNSS-1.ubx'
        raw_f3 = tmp / '2026-10-03_00-00-00_GNSS-1.ubx'
        make_empty_file(raw_f1)
        make_empty_file(raw_f2)
        make_empty_file(raw_f3)
        calls_f2 = []
        def recorder_f2(raw_file, output_dir, **kw):
            calls_f2.append((raw_file, kw))
            os.makedirs(output_dir, exist_ok=True)
            out = Path(output_dir) / 'x.obs'
            out.write_text('')
            return (out, None)
        def merge_stub_f2(obs_files, output_path):
            output_path.write_text('')
            return output_path
        conv_f2 = rc.RINEXConverter.__new__(rc.RINEXConverter)
        conv_f2.convert_raw_to_rinex_obs = recorder_f2
        orig_merge_f2 = rc.merge_rinex_obs
        rc.merge_rinex_obs = merge_stub_f2
        result_f2 = conv_f2.convert_raw_files_to_rinex_obs([raw_f1, raw_f2, raw_f3], tmp / 'out_f2', sample_interval=30)
        rc.merge_rinex_obs = orig_merge_f2
        if len(calls_f2) == 3:
            ok("F2: three convert calls with sample_interval")
        else:
            bad(f"F2: expected 3 calls, got {len(calls_f2)}")
        all_have_interval = all(
            kw.get('sample_interval') == 30
            for _, kw in calls_f2
        )
        if all_have_interval:
            ok("F2: all calls have sample_interval=30")
        else:
            bad("F2: not all calls have sample_interval=30")
    except Exception as e:
        bad(f"F2: exception: {e}")

    # Case G: No sample_interval -> None forwarded
    try:
        calls_g = []
        def recorder_g(raw_file, output_dir, **kw):
            calls_g.append((raw_file, kw))
            os.makedirs(output_dir, exist_ok=True)
            out = Path(output_dir) / 'x.obs'
            out.write_text('')
            return (out, None)
        def merge_stub_g(obs_files, output_path):
            output_path.write_text('')
            return output_path
        conv_g = rc.RINEXConverter.__new__(rc.RINEXConverter)
        conv_g.convert_raw_to_rinex_obs = recorder_g
        orig_merge_g = rc.merge_rinex_obs
        rc.merge_rinex_obs = merge_stub_g
        result_g = conv_g.convert_raw_files_to_rinex_obs([raw_f1, raw_f2, raw_f3], tmp / 'out_g')
        rc.merge_rinex_obs = orig_merge_g
        if len(calls_g) == 3:
            ok("G: three convert calls without sample_interval")
        else:
            bad(f"G: expected 3 calls, got {len(calls_g)}")
        all_none = all(
            kw.get('sample_interval') is None
            for _, kw in calls_g
        )
        if all_none:
            ok("G: all calls have sample_interval=None")
        else:
            bad("G: some calls have unexpected sample_interval")
    except Exception as e:
        bad(f"G: exception: {e}")

print(f"RESULT: {PASS} passed, {FAIL} failed")
sys.exit(FAIL)
PYEOF

exit $?
