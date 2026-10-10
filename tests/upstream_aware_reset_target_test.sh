#!/usr/bin/env bash
# Regression test for a confirmed-live bug (2026-10-14): a station
# mid-way through the Orange Pi branch-switch (its upstream repointed to
# origin/main via `git branch -u`, but its LOCAL branch name still
# feature/armbian-opi4pro-support until tools/branch_switch.sh's own fix
# renames it) would have every OTA-path script in this project reset/
# pull against "origin/<LOCAL branch name>" instead of the actual
# upstream - silently diverging the station from main the moment main
# gets a commit the frozen feature-branch ref doesn't.
#
# This test proves the fix directly against REAL git repos (not mocked
# git state) for:
#   - addons/tools/perform_update.sh's reset-target derivation
#   - tools/repo_update.sh's geomaxima_finish_interrupted_update()
# and via a static source check for update_controller.py's
# _get_update_target_ref() (a Python subprocess-git test would need a
# real git binary callable from Python with the same owner-detection
# dance update_controller.py does - the shell-level tests below already
# exercise the identical git-level logic for real).
#
# LINUX-ONLY (bash). Confirmed passing on WSL Ubuntu 24.04 this session.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
W=$(mktemp -d /tmp/gm_upstream_target_test.XXXXXX)
cleanup() { rm -rf "$W"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

export GIT_AUTHOR_NAME="test" GIT_AUTHOR_EMAIL="test@test" GIT_COMMITTER_NAME="test" GIT_COMMITTER_EMAIL="test@test"

setup_half_switched_repo() {
    # A repo whose local branch is named "feature-branch" but whose
    # upstream is already origin/main, with main AHEAD of what
    # feature-branch itself ever had - the exact state under test.
    local name="$1"
    local remote="$W/$name/remote.git"
    local station="$W/$name/station"
    mkdir -p "$remote"
    git init -q --bare "$remote"

    local seed="$W/$name/seed"
    git init -q -b main "$seed"
    (cd "$seed" && echo "v1" > file.txt && git add file.txt && git commit -q -m "initial")
    (cd "$seed" && git remote add origin "$remote" && git push -q origin main)
    git -C "$remote" symbolic-ref HEAD refs/heads/main

    (cd "$seed" && git checkout -q -b feature-branch && git push -q origin feature-branch)
    # main advances past feature-branch.
    (cd "$seed" && git checkout -q main && echo "v2" >> file.txt && git commit -q -am "advance main" && git push -q origin main)

    git clone -q "$remote" "$station"
    (cd "$station" && git checkout -q -b feature-branch origin/feature-branch)
    # Simulate the half-switched state: upstream repointed, local name
    # left alone.
    (cd "$station" && git branch -u origin/main >/dev/null 2>&1)

    echo "$station"
}

echo "== addons/tools/perform_update.sh: reset target derivation prefers @{u} over origin/<local name> =="
STATION=$(setup_half_switched_repo pu)
(cd "$STATION" && git fetch -q origin)

# Extract the EXACT reset-target derivation lines (not reimplemented) -
# from the BRANCH= assignment through the RESET_TARGET fallback's
# closing `fi` (the second `^fi$` after BRANCH's own, since BRANCH_RC's
# own `if ... fi` block comes first).
DERIVE_SRC=$(awk '/^BRANCH="\$\(GM_GIT_AS_OWNER/{found=1} found{print; if (/^fi$/) { fi_count++; if (fi_count==2) exit } }' "$REPO/addons/tools/perform_update.sh")
if ! echo "$DERIVE_SRC" | grep -q 'RESET_TARGET='; then
  bad "could not extract the RESET_TARGET derivation from perform_update.sh - has it changed shape?"
else
  OUT=$(bash -c "
GM_GIT_AS_OWNER() { \"\$@\"; }
log_status() { echo \"LOG \$1: \$2\"; }
cd '$STATION'
$DERIVE_SRC
echo \"RESET_TARGET=\$RESET_TARGET\"
" 2>&1)
  echo "$OUT"
  echo "$OUT" | grep -q "^RESET_TARGET=origin/main$" && ok "perform_update.sh resolves RESET_TARGET to origin/main (the real upstream), not origin/feature-branch" || bad "perform_update.sh did NOT prefer the upstream: $OUT"
fi

echo "== tools/repo_update.sh: geomaxima_finish_interrupted_update() uses the upstream-aware target =="
STATION2=$(setup_half_switched_repo ru)
(cd "$STATION2" && git fetch -q origin)
# Make it look "interrupted" so the function doesn't bail out at
# _gm_ota_running (it checks for a running perform_update*.sh process -
# fake that check out since this test isn't running a real OTA).
REPO_UPDATE_SRC=$(sed 's/_gm_ota_running || return 0//' "$REPO/tools/repo_update.sh")

OUT2=$(bash -c "
$REPO_UPDATE_SRC
GM_ALLOW_NONROOT=1
_gm_repo_root() { echo '$STATION2'; }
_gm_repo_log() { echo \"REPO_LOG: \$1\"; }
geomaxima_repo_normalize_ownership() { :; }
geomaxima_finish_interrupted_update
" 2>&1)
echo "$OUT2"
AFTER_HEAD2=$(cd "$STATION2" && git rev-parse HEAD)
MAIN_HEAD2=$(cd "$STATION2" && git rev-parse origin/main)
[ "$AFTER_HEAD2" = "$MAIN_HEAD2" ] && ok "repo_update.sh's finish-interrupted-update reset to origin/main (the upstream), not the stale origin/feature-branch" || bad "repo_update.sh reset to the wrong target (HEAD=$AFTER_HEAD2, expected main=$MAIN_HEAD2)"
echo "$OUT2" | grep -q "origin/main" && ok "repo_update.sh's own log output names origin/main as the target" || bad "repo_update.sh's log never mentioned origin/main"

echo "== addons/features/ota_update/update_controller.py: _get_update_target_ref() exists and prefers @{u} (static source check) =="
grep -q "_get_update_target_ref" "$REPO/addons/features/ota_update/update_controller.py" && ok "_get_update_target_ref() helper exists" || bad "_get_update_target_ref() helper not found"
grep -A30 "def _get_update_target_ref" "$REPO/addons/features/ota_update/update_controller.py" | grep -q "@{u}" && ok "_get_update_target_ref() queries @{u} (the real upstream)" || bad "_get_update_target_ref() does not reference @{u}"
grep -B2 -A2 "remote_commit = self._run_git_command" "$REPO/addons/features/ota_update/update_controller.py" | grep -q "target_ref" && ok "check_for_updates() uses target_ref (upstream-aware), not origin/{branch} directly" || bad "check_for_updates() still derives the remote commit from origin/{branch} directly"

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
