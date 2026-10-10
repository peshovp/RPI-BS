#!/usr/bin/env bash
# Unit-style test for archive_and_clean.sh against synthetic
# settings.conf + datadir fixtures - no real station needed.
#
# Covers the 2026-10-05 data-loss incident investigation: this script
# used to `source` the whole settings.conf as shell code and blindly
# interpolate archive_rotate/datadir/min_free_space into a destructive
# `find -delete`. These tests exercise every invalid-value case directly
# confirmed during that investigation (archive_rotate = 0, empty, "abc",
# a value below the 14-day floor, and a valid 60), plus a missing
# datadir, the free-space loop's termination/zip-only restriction, and
# that every deletion lands in audit.log.
#
# LINUX-ONLY: uses `stat -c` and GNU `find`/`date -d` syntax (GNU
# coreutils/findutils) - written for, and verified against, Debian/
# Raspberry Pi OS (the real station's OS), same as archive_and_clean.sh
# itself. Not expected to behave identically under Git Bash/MSYS on
# Windows (BSD-style stat/date differences) - confirmed passing 18/18 on
# WSL Ubuntu 24.04 this session; run there or on the real target OS, not
# assumed correct from a Windows-only run.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO/archive_and_clean.sh"
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

W="$(mktemp -d /tmp/gm_archive_clean_test.XXXXXX)"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

# Each case gets its own station dir (script dir + settings.conf) and
# its own datadir, and its own audit.log (redirected via sed'd copy of
# the script, so tests never touch the real
# /var/lib/rtkbase/audit.log).
make_case() {
  local name="$1"
  local case_dir="$W/$name"
  mkdir -p "$case_dir/data"
  sed "s#AUDIT_LOG_PATH=\"/var/lib/rtkbase/audit.log\"#AUDIT_LOG_PATH=\"$case_dir/audit.log\"#" "$SCRIPT" > "$case_dir/archive_and_clean.sh"
  chmod +x "$case_dir/archive_and_clean.sh"
  echo "$case_dir"
}

run_case() {
  local case_dir="$1"
  (cd "$case_dir" && ./archive_and_clean.sh) > "$1/stdout.log" 2> "$1/stderr.log"
  echo $?
}

echo "== Case A: archive_rotate=0 (the one confirmed-destructive value) =="
C=$(make_case "case_a")
cat > "$C/settings.conf" << EOF
[local_storage]
datadir=\$BASEDIR/data
archive_rotate='0'
min_free_space='500'
EOF
touch -d "2026-09-23" "$C/data/old1.zip"
touch -d "2026-10-01" "$C/data/recent1.zip"
touch -d "2026-08-03" "$C/data/survived.obs"
rc=$(run_case "$C")
cat "$C/stderr.log"
[[ -f "$C/data/old1.zip" && -f "$C/data/recent1.zip" && -f "$C/data/survived.obs" ]] && ok "Case A: nothing deleted despite archive_rotate=0" || bad "Case A: a file was deleted with archive_rotate=0"
grep -q "deletion_skipped" "$C/audit.log" 2>/dev/null && ok "Case A: deletion_skipped logged to audit.log" || bad "Case A: missing deletion_skipped audit event"

echo "== Case K: archive_rotate='08' (leading zero - confirmed to CRASH the old (( < 14 )) check as invalid octal) =="
C=$(make_case "case_k")
cat > "$C/settings.conf" << EOF
[local_storage]
datadir=\$BASEDIR/data
archive_rotate='08'
min_free_space='500'
EOF
touch -d "2026-09-23" "$C/data/old1.zip"
rc=$(run_case "$C")
cat "$C/stderr.log"
[[ "$rc" == "0" ]] && ok "Case K: script does not crash/exit nonzero on '08' (archiving still proceeds)" || bad "Case K: script exited $rc, expected 0"
[[ -f "$C/data/old1.zip" ]] && ok "Case K: nothing deleted with archive_rotate='08'" || bad "Case K: a file was deleted with archive_rotate='08'"
grep -q "leading zero" "$C/stderr.log" && ok "Case K: explicit leading-zero rejection message shown" || bad "Case K: missing leading-zero rejection message"

echo "== Case B: archive_rotate='' (empty) =="
C=$(make_case "case_b")
cat > "$C/settings.conf" << EOF
[local_storage]
datadir=\$BASEDIR/data
archive_rotate=''
min_free_space='500'
EOF
touch -d "2026-09-23" "$C/data/old1.zip"
rc=$(run_case "$C")
[[ -f "$C/data/old1.zip" ]] && ok "Case B: nothing deleted with archive_rotate empty" || bad "Case B: a file was deleted with archive_rotate empty"
grep -q "deletion_skipped" "$C/audit.log" 2>/dev/null && ok "Case B: deletion_skipped logged" || bad "Case B: missing deletion_skipped audit event"

echo "== Case C: archive_rotate='abc' (non-numeric) =="
C=$(make_case "case_c")
cat > "$C/settings.conf" << EOF
[local_storage]
datadir=\$BASEDIR/data
archive_rotate='abc'
min_free_space='500'
EOF
touch -d "2026-09-23" "$C/data/old1.zip"
rc=$(run_case "$C")
[[ -f "$C/data/old1.zip" ]] && ok "Case C: nothing deleted with archive_rotate=abc" || bad "Case C: a file was deleted with archive_rotate=abc"
grep -q "deletion_skipped" "$C/audit.log" 2>/dev/null && ok "Case C: deletion_skipped logged" || bad "Case C: missing deletion_skipped audit event"

echo "== Case D: archive_rotate='5' (below the 14-day retention floor) =="
C=$(make_case "case_d")
cat > "$C/settings.conf" << EOF
[local_storage]
datadir=\$BASEDIR/data
archive_rotate='5'
min_free_space='500'
EOF
touch -d "2026-09-01" "$C/data/old1.zip"
rc=$(run_case "$C")
[[ -f "$C/data/old1.zip" ]] && ok "Case D: nothing deleted with archive_rotate=5 (below floor)" || bad "Case D: a file was deleted with archive_rotate=5"
grep -q "retention floor" "$C/stderr.log" && ok "Case D: retention floor message shown" || bad "Case D: missing retention floor message"

echo "== Case E: archive_rotate='60' (valid) - normal operation =="
C=$(make_case "case_e")
cat > "$C/settings.conf" << EOF
[local_storage]
datadir=\$BASEDIR/data
archive_rotate='60'
min_free_space='500'
EOF
touch -d "96 days ago" "$C/data/old_beyond60.zip"
touch -d "6 days ago" "$C/data/recent_within60.zip"
rc=$(run_case "$C")
[[ ! -f "$C/data/old_beyond60.zip" ]] && ok "Case E: 96-day-old zip deleted" || bad "Case E: 96-day-old zip NOT deleted"
[[ -f "$C/data/recent_within60.zip" ]] && ok "Case E: 6-day-old zip kept" || bad "Case E: 6-day-old zip was wrongly deleted"
grep -q "age_based_delete" "$C/audit.log" 2>/dev/null && ok "Case E: age_based_delete logged to audit.log" || bad "Case E: missing age_based_delete audit event"

echo "== Case F: datadir missing entirely =="
C=$(make_case "case_f")
cat > "$C/settings.conf" << EOF
[local_storage]
datadir=\$BASEDIR/nonexistent_dir
archive_rotate='60'
min_free_space='500'
EOF
rc=$(run_case "$C")
[[ "$rc" != "0" ]] && ok "Case F: exits non-zero when datadir missing" || bad "Case F: exited 0 despite missing datadir"
grep -q "refused" "$C/audit.log" 2>/dev/null && ok "Case F: refused logged to audit.log" || bad "Case F: missing refused audit event"

echo "== Case G: low free space, only raw (.ubx/.obs) files present - must terminate, delete nothing, alert =="
C=$(make_case "case_g")
cat > "$C/settings.conf" << EOF
[local_storage]
datadir=\$BASEDIR/data
archive_rotate='60'
min_free_space='999999999'
EOF
touch -d "200 days ago" "$C/data/raw1.ubx"
touch -d "200 days ago" "$C/data/raw2.obs"
rc=$(timeout 10 bash -c "cd '$C' && ./archive_and_clean.sh > stdout.log 2> stderr.log"; echo $?)
[[ "$rc" != "124" ]] && ok "Case G: terminated (did not hang/infinite-loop)" || bad "Case G: TIMED OUT - infinite loop"
[[ -f "$C/data/raw1.ubx" && -f "$C/data/raw2.obs" ]] && ok "Case G: raw files never touched by the free-space loop" || bad "Case G: a raw file was deleted by the free-space loop"
grep -q "deletion_skipped" "$C/audit.log" 2>/dev/null && ok "Case G: deletion_skipped/low-space alert logged" || bad "Case G: missing low-space alert in audit.log"

echo "== Case H: invalid archive_rotate still allows the zip/archive step to run (datadir valid) =="
C=$(make_case "case_h")
cat > "$C/settings.conf" << EOF
[local_storage]
datadir=\$BASEDIR/data
archive_rotate='0'
min_free_space='500'
EOF
rc=$(run_case "$C")
[[ "$rc" == "0" ]] && ok "Case H: script exits 0 (archiving proceeds) despite invalid archive_rotate" || bad "Case H: exited $rc, expected 0"

echo "== Case J: audit.log not writable -> message still lands in stderr AND logger, never silent =="
C=$(make_case "case_j")
# make_case() redirects AUDIT_LOG_PATH into $C itself - replace that with
# a path this test can make genuinely unwritable (root:root 0444 or
# similar is what the live incident found; a read-only file reproduces
# the same write failure without needing root to chown it away from us).
mkdir -p "$C/unwritable_dir"
touch "$C/unwritable_dir/audit.log"
chmod 444 "$C/unwritable_dir/audit.log"
sed -i "s#AUDIT_LOG_PATH=\"$C/audit.log\"#AUDIT_LOG_PATH=\"$C/unwritable_dir/audit.log\"#" "$C/archive_and_clean.sh"
cat > "$C/settings.conf" << EOF
[local_storage]
datadir=\$BASEDIR/data
archive_rotate='0'
min_free_space='500'
EOF
touch -d "2026-09-23" "$C/data/old1.zip"
run_case "$C" > /dev/null
chmod 755 "$C/unwritable_dir" 2>/dev/null
grep -q "AUDIT LOG WRITE FAILED" "$C/stderr.log" && ok "Case J: audit write failure reported on stderr" || bad "Case J: audit write failure NOT reported on stderr"
grep -q "deletion_skipped" "$C/stderr.log" && ok "Case J: the actual event content (deletion_skipped) is preserved in the stderr fallback, not just a generic error" || bad "Case J: event content lost in the stderr fallback"

echo "== Case I: archive_and_clean.sh is tracked as executable in git =="
if git -C "$REPO" ls-files -s archive_and_clean.sh | grep -q '^100755'; then
    ok "Case I: archive_and_clean.sh has the executable bit in git"
else
    bad "Case I: archive_and_clean.sh is NOT tracked as executable (100644)"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
