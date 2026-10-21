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

def make_header_line(content, label):
    return content.ljust(60) + label.ljust(20)

def make_header_end_line():
    return ''.ljust(60) + 'END OF HEADER'.ljust(20)

def make_rinex_file(path, epochs, include_comment=False, crlf=False, no_header_end=False, no_trailing_pad=False):
    lines = []
    lines.append(make_header_line('     3.04           OBSERVATION DATA    M: Mixed', 'RINEX VERSION / TYPE'))
    lines.append(make_header_line('CONVBIN EX 2.5.0                        20261019 131032 UTC', 'PGM / RUN BY / DATE'))
    lines.append(make_header_line('BASE', 'MARKER NAME'))
    lines.append(make_header_line("'U-blox_ZED-F9P'    '1.51'", 'REC # / TYPE / VERS'))
    lines.append(make_header_line('  4207184.6050  2091450.6581  4299319.8440', 'APPROX POSITION XYZ'))
    lines.append(make_header_line('G    4 C1C L1C C2X L2X', 'SYS / # / OBS TYPES'))
    if include_comment:
        lines.append(make_header_line('FIRST-FILE-ONLY', 'COMMENT'))
    if no_header_end:
        pass
    elif no_trailing_pad:
        lines.append(''.ljust(60) + 'END OF HEADER')
    else:
        lines.append(make_header_end_line())

    for epoch in epochs:
        lines.append(f'> 2026 10 19 {epoch:02d} 00 00.0060000  0  2')
        lines.append('G01  22000000.123 7  115000000.456 7')
        lines.append('G02  23000000.456 7  121000000.789 7')

    with open(path, 'w', newline='') as f:
        if crlf:
            for line in lines:
                f.write(line + '\r\n')
        else:
            for line in lines:
                f.write(line + '\n')

with tempfile.TemporaryDirectory() as tmpdir:
    tmp = Path(tmpdir)

    # Case A: Two padded files
    f1 = tmp / 'seg1.obs'
    f2 = tmp / 'seg2.obs'
    out_a = tmp / 'merged_a.obs'
    make_rinex_file(f1, [4, 5], include_comment=True)
    make_rinex_file(f2, [6, 7])
    result_a = rc.merge_rinex_obs([f1, f2], out_a)
    with open(out_a, 'r') as f:
        content_a = f.read()
    if 'FIRST-FILE-ONLY' in content_a:
        ok("A: merged file has first file's comment")
    else:
        bad("A: merged file missing first file's comment")
    if content_a.count('END OF HEADER') == 1:
        ok("A: END OF HEADER appears exactly once")
    else:
        bad(f"A: END OF HEADER appears {content_a.count('END OF HEADER')} times")
    if content_a.count('RINEX VERSION / TYPE') == 1:
        ok("A: RINEX VERSION / TYPE appears exactly once")
    else:
        bad(f"A: RINEX VERSION / TYPE appears {content_a.count('RINEX VERSION / TYPE')} times")
    epoch_lines_a = [l for l in content_a.split('\n') if l.startswith('> 2026')]
    if len(epoch_lines_a) == 4:
        ok("A: correct number of epochs (4)")
    else:
        bad(f"A: wrong number of epochs ({len(epoch_lines_a)})")
    expected_last_epoch = '> 2026 10 19 07 00 00.0060000  0  2'
    if epoch_lines_a and epoch_lines_a[-1] == expected_last_epoch:
        ok("A: last epoch from second file present")
    else:
        bad(f"A: last epoch wrong (got {epoch_lines_a[-1] if epoch_lines_a else 'none'})")
    if result_a == out_a:
        ok("A: returns output path")
    else:
        bad("A: did not return output path")

    # Case B: Three padded files
    f3 = tmp / 'seg3.obs'
    out_b = tmp / 'merged_b.obs'
    make_rinex_file(f3, [8, 9])
    result_b = rc.merge_rinex_obs([f1, f2, f3], out_b)
    with open(out_b, 'r') as f:
        content_b = f.read()
    epoch_lines_b = [l for l in content_b.split('\n') if l.startswith('> 2026')]
    if len(epoch_lines_b) == 6:
        ok("B: three files merged, correct epoch count (6)")
    else:
        bad(f"B: wrong epoch count ({len(epoch_lines_b)})")
    expected_epochs = ['04', '05', '06', '07', '08', '09']
    actual_epochs = [l.split()[4] for l in epoch_lines_b]
    if actual_epochs == expected_epochs:
        ok("B: epochs in correct order")
    else:
        bad(f"B: epochs out of order: {actual_epochs}")

    # Case C: CRLF line endings
    f2_crlf = tmp / 'seg2_crlf.obs'
    out_c = tmp / 'merged_c.obs'
    make_rinex_file(f2_crlf, [6, 7], crlf=True)
    result_c = rc.merge_rinex_obs([f1, f2_crlf], out_c)
    with open(out_c, 'r') as f:
        content_c = f.read()
    epoch_lines_c = [l for l in content_c.split('\n') if l.startswith('> 2026')]
    if len(epoch_lines_c) == 4:
        ok("C: CRLF file merged correctly")
    else:
        bad(f"C: CRLF merge failed ({len(epoch_lines_c)} epochs)")

    # Case D: No trailing padding on header-end
    f2_nopad = tmp / 'seg2_nopad.obs'
    out_d = tmp / 'merged_d.obs'
    make_rinex_file(f2_nopad, [6, 7], no_trailing_pad=True)
    result_d = rc.merge_rinex_obs([f1, f2_nopad], out_d)
    with open(out_d, 'r') as f:
        content_d = f.read()
    epoch_lines_d = [l for l in content_d.split('\n') if l.startswith('> 2026')]
    if len(epoch_lines_d) == 4:
        ok("D: no-trailing-pad file merged correctly")
    else:
        bad(f"D: no-trailing-pad merge failed ({len(epoch_lines_d)} epochs)")

    # Case E: No END OF HEADER line
    f2_noend = tmp / 'seg2_noend.obs'
    out_e = tmp / 'merged_e.obs'
    make_rinex_file(f2_noend, [6, 7], no_header_end=True)
    logger = logging.getLogger('rinex_converter')
    class TestHandler(logging.Handler):
        def __init__(self):
            super().__init__()
            self.messages = []
        def emit(self, record):
            self.messages.append(record.getMessage())
    handler = TestHandler()
    logger.addHandler(handler)
    result_e = rc.merge_rinex_obs([f1, f2_noend], out_e)
    logger.removeHandler(handler)
    with open(out_e, 'r') as f:
        content_e = f.read()
    epoch_lines_e = [l for l in content_e.split('\n') if l.startswith('> 2026')]
    if len(epoch_lines_e) == 2:
        ok("E: no-EOF file contributed nothing")
    else:
        bad(f"E: no-EOF file contributed data ({len(epoch_lines_e)} epochs)")
    if result_e == out_e:
        ok("E: returns output path")
    else:
        bad("E: did not return output path")
    if any("no 'END OF HEADER' line" in m for m in handler.messages):
        ok("E: warning logged")
    else:
        bad("E: warning not logged")

    # Case F: Single input
    out_f1 = tmp / 'merged_f1.obs'
    result_f1 = rc.merge_rinex_obs([f1], out_f1)
    with open(f1, 'r') as f:
        orig = f.read()
    with open(out_f1, 'r') as f:
        copy = f.read()
    if orig == copy:
        ok("F: single input copied correctly")
    else:
        bad("F: single input copy differs")
    result_f2 = rc.merge_rinex_obs([f1], f1)
    if result_f2 == f1:
        ok("F: single input same path returns path")
    else:
        bad("F: single input same path failed")

    # Case G: Empty list
    result_g = rc.merge_rinex_obs([], tmp / 'merged_g.obs')
    if result_g is None:
        ok("G: empty list returns None")
    else:
        bad("G: empty list did not return None")

print(f"RESULT: {PASS} passed, {FAIL} failed")
sys.exit(FAIL)
PYEOF

exit $?
