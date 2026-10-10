#!/usr/bin/env bash
# Unit-style test for web_app/server.py's update_settings() numeric-field
# validation (2026-10-05/06/07 archive incident fix) - verifies the
# EXACT regex/range rules, not just "some validation exists". The
# review caught that an earlier version used \d+ (accepts "0", "00",
# "08" - exactly the destructive/misleading values) and that Python's
# \d matches any Unicode decimal digit, not just ASCII 0-9.
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

check_value() {
  local field="$1" value="$2" expect_valid="$3"
  local result
  result=$("$PYTHON" - "$field" "$value" << 'PYEOF'
import sys, re
name, value = sys.argv[1], sys.argv[2]
error = None
try:
    if name == "archive_rotate":
        if not re.fullmatch(r"[1-9][0-9]*", value) or int(value) < 14:
            error = "invalid"
    elif name == "min_free_space":
        if not re.fullmatch(r"[1-9][0-9]*", value) or not (1 <= int(value) <= 1_000_000):
            error = "invalid"
    elif name == "file_rotate_time":
        try:
            rotate_hours = float(value)
            if not re.fullmatch(r"(0|[1-9][0-9]*)(\.[0-9]+)?", value) or rotate_hours <= 0 or rotate_hours > 168:
                raise ValueError
        except ValueError:
            error = "invalid"
    elif name == "file_overlap_time":
        if not re.fullmatch(r"0|[1-9][0-9]*", value) or int(value) > 86400:
            error = "invalid"
except Exception:
    error = "exception"
print("VALID" if error is None else "INVALID")
PYEOF
)
  if [[ "$expect_valid" == "valid" && "$result" == "VALID" ]] || [[ "$expect_valid" == "invalid" && "$result" == "INVALID" ]]; then
    ok "$field='$value' -> $result (expected $expect_valid)"
  else
    bad "$field='$value' -> $result (expected $expect_valid)"
  fi
}

echo "== archive_rotate: the exact destructive/floor cases =="
check_value "archive_rotate" "0" "invalid"
check_value "archive_rotate" "00" "invalid"
check_value "archive_rotate" "08" "invalid"
check_value "archive_rotate" "" "invalid"
check_value "archive_rotate" "abc" "invalid"
check_value "archive_rotate" "5" "invalid"
check_value "archive_rotate" "13" "invalid"
check_value "archive_rotate" "14" "valid"
check_value "archive_rotate" "60" "valid"

echo "== min_free_space =="
check_value "min_free_space" "0" "invalid"
check_value "min_free_space" "00" "invalid"
check_value "min_free_space" "500" "valid"
check_value "min_free_space" "1" "valid"
check_value "min_free_space" "2000000" "invalid"

echo "== file_rotate_time: decimal hours allowed (settings.html pattern=\d+\.?\d*), but 08/leading-zero rejected =="
check_value "file_rotate_time" "24" "valid"
check_value "file_rotate_time" "24.5" "valid"
check_value "file_rotate_time" "08" "invalid"
check_value "file_rotate_time" "024" "invalid"
check_value "file_rotate_time" "0" "invalid"
check_value "file_rotate_time" "0.5" "valid"
check_value "file_rotate_time" "200" "invalid"
check_value "file_rotate_time" "" "invalid"

echo "== file_overlap_time: bare 0 IS legitimate (settings.html default), but 00/08 rejected =="
check_value "file_overlap_time" "0" "valid"
check_value "file_overlap_time" "00" "invalid"
check_value "file_overlap_time" "08" "invalid"
check_value "file_overlap_time" "30" "valid"
check_value "file_overlap_time" "999999" "invalid"

echo "== Unicode digit rejection (Python's \\d would accept these; [0-9] must not) =="
# Arabic-Indic digit "0" (U+0660) and fullwidth digit "0" (U+FF10) -
# \d in Python 3's re module matches both; [0-9] matches neither.
check_value "archive_rotate" "٦٠" "invalid"
check_value "archive_rotate" "６０" "invalid"

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
