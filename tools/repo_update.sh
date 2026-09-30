#!/usr/bin/env bash
# =============================================================================
#  tools/repo_update.sh
#  Meant to be SOURCED. Keeps the git checkout updatable by its owner.
#
#  CONFIRMED LIVE (test station, OTA delivering 2b01198): the OTA runs git
#  as the repo owner, but earlier root-run git (an older updater, the
#  upstream installer's `git pull`) had left a root-owned tests/ directory
#  and root-owned .git/objects directories. `git reset --hard origin/main`
#  then failed half-way ("unable to unlink old 'tests/dns_setup_test.sh':
#  Permission denied" / "Could not reset index file"): most new files were
#  written, HEAD and the index stayed on the old commit, and the updater -
#  which piped the reset through `tee` - reported success.
#
#  geomaxima_repo_normalize_ownership <repo>
#      Hand every path in the repo (working tree AND .git) that isn't owned
#      by the repo owner back to it. Root services may keep writing there;
#      root isn't restricted by ownership, the owner is.
#
#  geomaxima_finish_interrupted_update
#      Recovery hook for stations whose updater is an OLDER copy that can't
#      recover by itself. Such an updater, after its (failing) reset, still
#      sources tools/wireguard_setup.sh and tools/dns_setup.sh from disk as
#      root - and the reset DID write those new files. Both call this first:
#      if an OTA is running and the checkout isn't at origin/<branch> (or has
#      tracked changes), normalize ownership and redo the reset as the owner.
#      A no-op when the checkout is already clean at origin/<branch> (every
#      update by the current updater, which normalizes before resetting) or
#      when no OTA is running (install.sh also calls those hooks - a
#      developer's checkout must never be reset from there).
#
#  Test seams (never set in production): GM_ALLOW_NONROOT=1 lets the
#  functions run without root; GM_OTA_RUNNING=0/1 overrides the
#  "is an OTA running" detection.
# =============================================================================

_gm_repo_log() { echo "[repo] $*"; }

# Repo root = the directory above tools/ holding this file.
_gm_repo_root() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
    dirname "$here"
}

# _gm_foreign_paths <repo> <owner>: NUL-separated paths under the repo
# (working tree and .git; -xdev: never into another mounted filesystem)
# NOT owned by <owner>. GM_TEST_FOREIGN_LIST (tests only - no second real
# UID is available there) names a newline-separated list to use instead.
_gm_foreign_paths() {
    if [[ -n "${GM_TEST_FOREIGN_LIST:-}" ]]; then
        [[ -s "$GM_TEST_FOREIGN_LIST" ]] && tr '\n' '\0' < "$GM_TEST_FOREIGN_LIST"
        return 0
    fi
    find "$1" -xdev \! -user "$2" -print0 2>/dev/null
}

geomaxima_repo_normalize_ownership() {
    local repo="${1:-$(_gm_repo_root)}" owner n
    owner="$(stat -c '%U' "$repo" 2>/dev/null)"
    if [[ -z "$owner" || "$owner" == "root" ]]; then
        _gm_repo_log "repo owner is '${owner:-unknown}' - ownership left as it is"
        return 0
    fi
    if [[ $EUID -ne 0 && "${GM_ALLOW_NONROOT:-0}" != 1 ]]; then
        _gm_repo_log "not root - cannot normalize ownership of $repo"
        return 1
    fi
    n="$(_gm_foreign_paths "$repo" "$owner" | tr -cd '\0' | wc -c)"
    if [[ "$n" -eq 0 ]]; then
        _gm_repo_log "ownership OK: everything under $repo belongs to $owner"
        return 0
    fi
    _gm_repo_log "handing $n path(s) under $repo not owned by $owner back to $owner"
    _gm_foreign_paths "$repo" "$owner" | xargs -0 -r chown -h "$owner": 2>&1 | sed 's/^/[repo] chown: /'
    n="$(_gm_foreign_paths "$repo" "$owner" | tr -cd '\0' | wc -c)"
    if [[ "$n" -ne 0 ]]; then
        _gm_repo_log "ERROR: $n path(s) still not owned by $owner"
        return 1
    fi
    return 0
}

# Is an OTA update running right now? (the updater may run from a private
# copy named /tmp/perform_update.XXXXXX.sh - see perform_update.sh)
_gm_ota_running() {
    if [[ -n "${GM_OTA_RUNNING:-}" ]]; then
        [[ "$GM_OTA_RUNNING" == 1 ]]; return
    fi
    pgrep -f 'perform_update[^/]*\.sh' >/dev/null 2>&1
}

geomaxima_finish_interrupted_update() {
    local repo owner branch head target dirty out rc
    repo="$(_gm_repo_root)" || return 0
    [[ -d "$repo/.git" ]] || return 0
    _gm_ota_running || return 0
    owner="$(stat -c '%U' "$repo" 2>/dev/null)"
    [[ -n "$owner" && "$owner" != root ]] || return 0
    [[ $EUID -eq 0 || "${GM_ALLOW_NONROOT:-0}" == 1 ]] || return 0

    local as_owner=(sudo -u "$owner")
    [[ "$(id -un)" == "$owner" ]] && as_owner=()
    branch="$("${as_owner[@]}" git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)" || return 0
    target="$("${as_owner[@]}" git -C "$repo" rev-parse --verify -q "origin/$branch" 2>/dev/null)" || return 0
    head="$("${as_owner[@]}" git -C "$repo" rev-parse HEAD 2>/dev/null)"
    dirty="$("${as_owner[@]}" git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)"
    if [[ "$head" == "$target" && -z "$dirty" ]]; then
        return 0
    fi

    _gm_repo_log "interrupted update detected: HEAD ${head:0:7}, origin/$branch ${target:0:7}, $(printf '%s' "$dirty" | grep -c .) tracked change(s) - finishing it"
    geomaxima_repo_normalize_ownership "$repo"
    out="$("${as_owner[@]}" git -C "$repo" reset --hard "origin/$branch" 2>&1)" && rc=0 || rc=$?
    printf '%s\n' "$out" | sed 's/^/[repo] git: /'
    head="$("${as_owner[@]}" git -C "$repo" rev-parse HEAD 2>/dev/null)"
    dirty="$("${as_owner[@]}" git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)"
    if [[ $rc -eq 0 && "$head" == "$target" && -z "$dirty" ]]; then
        _gm_repo_log "update finished: checkout is clean at origin/$branch (${target:0:7})"
    else
        _gm_repo_log "ERROR: could not finish the update (reset exit $rc, HEAD ${head:0:7}, target ${target:0:7}) - the next OTA will retry"
    fi
    return 0
}
