#!/usr/bin/env bash
# Every tracked *.sh file must be executable (100755) in git, regardless
# of what mode bit it happens to have on whatever machine last committed
# it. A commit made from a Windows checkout with core.fileMode=true (or
# unset, which defaults to true on most installs) can silently record a
# *.sh file as 100644 even though it was runnable on disk - this exact
# mismatch was found live for tools/check_rtcm_height.sh and 15 other
# scripts after an OTA pull. install.sh scripts generally re-chmod +x
# their own install targets at install time (confirmed for
# addons/PRIDE-PPPAR/install.sh's "sudo -u ... chmod +x" step), but a
# script invoked DIRECTLY (./script.sh, or systemd ExecStart=.../script.sh
# with no interpreter prefix) depends on git's own tracked mode bit being
# right at checkout time - this test exists so that dependency is never
# silently broken again.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

echo "== Every tracked *.sh file must be 100755 in git =="

non_exec=()
while IFS=$'\t' read -r meta path; do
    mode="${meta%% *}"
    if [[ "$mode" != "100755" ]]; then
        non_exec+=("$path (currently $mode)")
    fi
done < <(git ls-files -s -- '*.sh')

if [[ ${#non_exec[@]} -eq 0 ]]; then
    ok "all tracked *.sh files are 100755"
else
    bad "the following tracked *.sh files are NOT executable in git:"
    for entry in "${non_exec[@]}"; do
        echo "    - $entry"
    done
    echo
    echo "  Fix: git update-index --chmod=+x <path>  (for each file above), then commit."
    echo "  If this keeps happening from the SAME machine, check 'git config core.fileMode' -"
    echo "  Windows checkouts often have it unset/true, which can make git record a file's"
    echo "  mode from NTFS (which has no real execute bit) instead of what the file actually"
    echo "  needs; 'git config core.fileMode false' on that machine stops git from tracking"
    echo "  mode changes from it at all, so an existing +x in the repo is never undone by a"
    echo "  future commit made there."
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
