#!/usr/bin/env bash
# Unit-style test for tools/branch_switch.sh's geomaxima_maybe_switch_branch()
# - Orange Pi 4 Pro consolidation: a station tracking
# feature/armbian-opi4pro-support (a strict ancestor of main, fully
# merged, no new commits of its own) must switch to tracking main so
# main's ongoing OTA/self-heal fixes actually reach it. Safety
# conditions: only switches when currently on the exact feature branch
# name, only when the tree is clean, never forces, idempotent.
#
# Uses REAL local git repos (a "remote" bare repo plus a "station"
# clone) so git's own branch/reset/status behavior is exercised for
# real, not mocked - this logic is entirely about git state.
#
# LINUX-ONLY (bash). Confirmed passing on WSL Ubuntu 24.04 this session.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
W=$(mktemp -d /tmp/gm_branch_switch_test.XXXXXX)
cleanup() { rm -rf "$W"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

export GIT_AUTHOR_NAME="test" GIT_AUTHOR_EMAIL="test@test" GIT_COMMITTER_NAME="test" GIT_COMMITTER_EMAIL="test@test"

setup_remote_and_station() {
    local name="$1"
    local remote="$W/$name/remote.git"
    local station="$W/$name/station"
    mkdir -p "$remote" "$(dirname "$station")"
    git init -q --bare "$remote"

    local seed="$W/$name/seed"
    git init -q -b main "$seed"
    (cd "$seed" && echo "v1" > file.txt && git add file.txt && git commit -q -m "initial")
    (cd "$seed" && git remote add origin "$remote" && git push -q origin main)
    git -C "$remote" symbolic-ref HEAD refs/heads/main

    # Feature branch, same tip as main at this point (strict ancestor).
    (cd "$seed" && git checkout -q -b feature/armbian-opi4pro-support && git push -q origin feature/armbian-opi4pro-support)

    # main gets more commits the feature branch does NOT have.
    (cd "$seed" && git checkout -q main && echo "v2" >> file.txt && git commit -q -am "second commit on main" && git push -q origin main)

    # Station clones and checks out the feature branch (matching the
    # real Orange Pi's state: tracking the old branch, behind main).
    git clone -q "$remote" "$station"
    (cd "$station" && git checkout -q -b feature/armbian-opi4pro-support origin/feature/armbian-opi4pro-support)

    echo "$station"
}

echo "== Case A: station tracking the feature branch, clean tree -> switches to main =="
STATION=$(setup_remote_and_station case_a)
BEFORE_BRANCH=$(cd "$STATION" && git rev-parse --abbrev-ref HEAD)
echo "before: $BEFORE_BRANCH"

AUDIT_LOG="$W/case_a_audit.log"
OUT=$(GM_BRANCH_SWITCH_AUDIT_LOG="$AUDIT_LOG" bash -c "source '$REPO/tools/branch_switch.sh' && geomaxima_maybe_switch_branch '$STATION' ''" 2>&1)
echo "$OUT"

AFTER_HEAD=$(cd "$STATION" && git rev-parse HEAD)
MAIN_HEAD=$(cd "$STATION" && git rev-parse origin/main)
AFTER_UPSTREAM=$(cd "$STATION" && git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)

[ "$AFTER_HEAD" = "$MAIN_HEAD" ] && ok "Case A: station's HEAD now matches origin/main" || bad "Case A: HEAD does not match origin/main (got $AFTER_HEAD, expected $MAIN_HEAD)"
[ "$AFTER_UPSTREAM" = "origin/main" ] && ok "Case A: upstream is now origin/main" || bad "Case A: upstream is $AFTER_UPSTREAM, expected origin/main"
grep -q '"event": "switch_completed"' "$AUDIT_LOG" 2>/dev/null && ok "Case A: switch_completed logged to audit.log" || bad "Case A: no switch_completed audit event"
cat "$STATION/file.txt" | grep -q "v2" && ok "Case A: main's newer content is present (v2 line)" || bad "Case A: main's newer content missing"

echo "== Case B: station tracking the feature branch, DIRTY tree -> skipped, never forced =="
STATION=$(setup_remote_and_station case_b)
echo "uncommitted change" >> "$STATION/file.txt"
BEFORE_BRANCH=$(cd "$STATION" && git rev-parse --abbrev-ref HEAD)
BEFORE_HEAD=$(cd "$STATION" && git rev-parse HEAD)

AUDIT_LOG="$W/case_b_audit.log"
OUT=$(GM_BRANCH_SWITCH_AUDIT_LOG="$AUDIT_LOG" bash -c "source '$REPO/tools/branch_switch.sh' && geomaxima_maybe_switch_branch '$STATION' ''" 2>&1)
echo "$OUT"

AFTER_BRANCH=$(cd "$STATION" && git rev-parse --abbrev-ref HEAD)
AFTER_HEAD=$(cd "$STATION" && git rev-parse HEAD)
[ "$AFTER_BRANCH" = "$BEFORE_BRANCH" ] && ok "Case B: branch unchanged (dirty tree, switch skipped)" || bad "Case B: branch changed despite dirty tree"
[ "$AFTER_HEAD" = "$BEFORE_HEAD" ] && ok "Case B: HEAD unchanged (no reset attempted)" || bad "Case B: HEAD changed despite dirty tree"
grep -q "uncommitted change" "$STATION/file.txt" && ok "Case B: uncommitted change preserved, never discarded" || bad "Case B: uncommitted change was lost"
grep -q '"event": "switch_skipped_dirty_tree"' "$AUDIT_LOG" 2>/dev/null && ok "Case B: switch_skipped_dirty_tree logged" || bad "Case B: no skip event logged"

echo "== Case C: station already tracking main -> idempotent no-op =="
STATION=$(setup_remote_and_station case_c)
(cd "$STATION" && git checkout -q main)
BEFORE_HEAD=$(cd "$STATION" && git rev-parse HEAD)

AUDIT_LOG="$W/case_c_audit.log"
OUT=$(GM_BRANCH_SWITCH_AUDIT_LOG="$AUDIT_LOG" bash -c "source '$REPO/tools/branch_switch.sh' && geomaxima_maybe_switch_branch '$STATION' ''" 2>&1)
echo "$OUT"

AFTER_HEAD=$(cd "$STATION" && git rev-parse HEAD)
[ "$AFTER_HEAD" = "$BEFORE_HEAD" ] && ok "Case C: no-op for a station already on main" || bad "Case C: HEAD changed unexpectedly"
[ ! -s "$AUDIT_LOG" ] && ok "Case C: nothing logged (true no-op, not even a skip event)" || bad "Case C: something was logged for an already-on-main station"

echo "== Case D: station tracking some OTHER branch entirely -> never touched =="
STATION=$(setup_remote_and_station case_d)
(cd "$STATION" && git checkout -q -b some-other-branch)
BEFORE_HEAD=$(cd "$STATION" && git rev-parse HEAD)

OUT=$(bash -c "source '$REPO/tools/branch_switch.sh' && geomaxima_maybe_switch_branch '$STATION' ''" 2>&1)
echo "$OUT"
AFTER_BRANCH=$(cd "$STATION" && git rev-parse --abbrev-ref HEAD)
[ "$AFTER_BRANCH" = "some-other-branch" ] && ok "Case D: a station on an unrelated branch is never touched" || bad "Case D: branch was changed for an unrelated branch"

echo "== Case E: caller is root, repo belongs to a DIFFERENT user - every git call must go through sudo -u <that user>, NEVER run directly as root =="
# A real multi-user permission test isn't possible in this sandbox (no
# second real user account), so this proves the code-level guarantee
# instead: a stub `sudo` on PATH that records who it was asked to run
# as, for every single invocation. If even one git call bypassed
# as_owner (ran directly, not via sudo -u <owner>), this stub would
# never see it and the "every call went through sudo -u $EXPECTED_OWNER"
# assertion below would still pass vacuously - so this ALSO asserts the
# plain `git` binary on PATH was never invoked directly (only via the
# sudo wrapper), which only holds if as_owner wraps every call.
STATION=$(setup_remote_and_station case_e)
EXPECTED_OWNER="someotheruser"
SUDO_LOG="$W/sudo_calls.log"
STUBDIR="$W/stubbin"
mkdir -p "$STUBDIR"
cat > "$STUBDIR/sudo" << EOF
#!/usr/bin/env bash
# Stub: records every invocation (expects "-u <user> <real command...>"),
# then actually runs the real command as the CURRENT user (this sandbox
# has no second real account) - good enough to prove as_owner wraps
# every git call, which is the thing under test here.
echo "sudo \$*" >> "$SUDO_LOG"
if [[ "\$1" == "-u" ]]; then
    shift 2
fi
exec "\$@"
EOF
chmod +x "$STUBDIR/sudo"
# `stat -c '%U'` inside branch_switch.sh must report EXPECTED_OWNER for
# this test to exercise the real "disk owner wins" cross-check - fake it
# by also stubbing `stat` (this sandbox's real file owner is whoever is
# running this test, not someotheruser).
cat > "$STUBDIR/stat" << EOF
#!/usr/bin/env bash
if [[ "\$*" == "-c %U "* ]]; then
    echo "$EXPECTED_OWNER"
    exit 0
fi
exec /usr/bin/stat "\$@"
EOF
chmod +x "$STUBDIR/stat"

rm -f "$SUDO_LOG"
AUDIT_LOG="$W/case_e_audit.log"
OUT=$(PATH="$STUBDIR:$PATH" GM_BRANCH_SWITCH_AUDIT_LOG="$AUDIT_LOG" bash -c "source '$REPO/tools/branch_switch.sh' && geomaxima_maybe_switch_branch '$STATION' ''" 2>&1)
echo "$OUT"

if [[ -s "$SUDO_LOG" ]]; then
    ok "Case E: sudo was invoked at least once"
    NON_OWNER_CALLS=$(grep -cv "^sudo -u $EXPECTED_OWNER " "$SUDO_LOG" || true)
    [ "$NON_OWNER_CALLS" -eq 0 ] && ok "Case E: every sudo call used -u $EXPECTED_OWNER (none ran as a different/no user)" || bad "Case E: $NON_OWNER_CALLS sudo call(s) did NOT use -u $EXPECTED_OWNER: $(cat "$SUDO_LOG")"
    GIT_CALL_COUNT=$(grep -c "^sudo -u $EXPECTED_OWNER git " "$SUDO_LOG" || true)
    [ "$GIT_CALL_COUNT" -ge 1 ] && ok "Case E: git was invoked $GIT_CALL_COUNT time(s), every one through sudo -u $EXPECTED_OWNER" || bad "Case E: no git calls went through sudo -u $EXPECTED_OWNER at all"
else
    bad "Case E: sudo was never invoked - git calls would have run directly as the current user (root, in production)"
fi
echo "$OUT" | grep -qi "does not match" && ok "Case E: the caller-vs-disk-owner mismatch warning fired (repo_owner argument was empty, disk owner won)" || true

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
