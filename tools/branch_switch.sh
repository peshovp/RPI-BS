#!/usr/bin/env bash
#
# GeoMaxima - 2026-10-13: Orange Pi 4 Pro consolidation. The feature
# branch feature/armbian-opi4pro-support is a strict ancestor of main
# (`git rev-list --left-right --count origin/main...HEAD` = "34 0" on the
# one station still tracking it) - already fully merged, so main's own
# OTA/self-heal fixes (this exact fix included) can never reach a
# station still tracking that branch, since its OTA never pulls anything
# new. This function switches such a station's tracking branch to main
# THROUGH CODE, with no manual branch switch on the station required:
#
#   - ONLY if the current branch is exactly feature/armbian-opi4pro-
#     support (never touches a station intentionally tracking some
#     other branch).
#   - ONLY if the working tree is clean (`git status --porcelain
#     --untracked-files=no` - ignored/untracked runtime files like
#     .update_status.json/geomaxima_ppp/ are allowed and never block
#     this, matching the normal OTA path's own tolerance for them).
#     Never forces past a dirty tree - logs a warning and skips.
#   - Idempotent: a station already on local branch main is a silent
#     no-op; a station on some OTHER unrelated local branch is also
#     left untouched.
#
# GeoMaxima - 2026-10-14 review fix: the first version of this function
# only repointed the UPSTREAM (`git branch -u origin/main`) without
# renaming the LOCAL branch - confirmed live (Orange Pi 4 Pro OTA to
# e009f5c) this left the switch half-done: `git status -sb` still showed
# `feature/armbian-opi4pro-support...origin/main`. That half-switched
# state is actually WORSE than doing nothing, because every OTA-path
# script in this project (perform_update.sh, repo_update.sh,
# update_controller.py's check_for_updates()) derives its reset/pull
# target from the LOCAL branch NAME via `git rev-parse --abbrev-ref
# HEAD`, not from the upstream - so "origin/$branch" would resolve to
# origin/feature/armbian-opi4pro-support, a ref that now never moves
# again, silently diverging the station from main the moment main gets
# a commit that ref doesn't. (Each of those call sites has its own fix,
# in this same commit, to prefer @{u} when set - but this function
# should not rely on every caller remembering to do that; it completes
# the job itself.) Fixed: this function now actually renames the local
# branch to main (`git checkout -B main origin/main`), handling three
# starting states:
#   1. Local branch is exactly GM_BRANCH_SWITCH_FROM, upstream not yet
#      set to main (a station that has never been touched by this
#      function before) - full switch: fetch, checkout -B, delete the
#      old local branch name (NEVER the remote one).
#   2. Local branch is still GM_BRANCH_SWITCH_FROM, but its upstream is
#      ALREADY origin/main (the exact half-switched state this fix
#      addresses) - finishes the job: checkout -B, delete the old local
#      name, no separate "already switched" logging since from this
#      function's own perspective it's the same one-step operation.
#   3. Local branch is already GM_BRANCH_SWITCH_TO (main) - idempotent
#      no-op, logs nothing.
# A station on some OTHER local branch entirely (never matching
# GM_BRANCH_SWITCH_FROM) is never touched, regardless of its upstream.
#
# Called from BOTH tools/post_update.sh (for every station after a
# normal OTA, where the hand-off runs) AND web_app/server.py's startup
# self-heal (for a station whose CURRENT perform_update.sh predates the
# post_update.sh hand-off entirely - confirmed true for the Orange Pi 4
# Pro station, still on the 68c61fe perform_update.sh, which has no
# knowledge of post_update.sh at all).
set -u

GM_BRANCH_SWITCH_AUDIT_LOG="${GM_BRANCH_SWITCH_AUDIT_LOG:-/var/lib/rtkbase/audit.log}"
_gm_branch_switch_audit_log() {
    local event="$1" details_json="$2"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%S.%6N")
    mkdir -p "$(dirname "${GM_BRANCH_SWITCH_AUDIT_LOG}")" 2>/dev/null
    printf '{"timestamp": "%s", "category": "branch_switch", "event": "%s", "details": %s}\n' \
        "${ts}" "${event}" "${details_json}" >> "${GM_BRANCH_SWITCH_AUDIT_LOG}" 2>/dev/null || true
}

# GM_BRANCH_SWITCH_FROM/_TO are overridable only for tests - production
# callers never set them, so this always targets the real migration
# (feature/armbian-opi4pro-support -> main).
GM_BRANCH_SWITCH_FROM="${GM_BRANCH_SWITCH_FROM:-feature/armbian-opi4pro-support}"
GM_BRANCH_SWITCH_TO="${GM_BRANCH_SWITCH_TO:-main}"

geomaxima_maybe_switch_branch() {
    local repo_path="${1:?repo path required}"
    local repo_owner="${2:-}"

    # GeoMaxima - 2026-10-13 review fix: this function is called from
    # web_app/server.py's startup self-heal, which runs as ROOT. Every
    # git command below MUST run as the repo's actual owner, never as
    # root - running git as root against a non-root-owned working tree
    # triggers git's "detected dubious ownership" refusal (confirmed live
    # elsewhere in this project - see perform_update.sh's own
    # GM_GIT_AS_OWNER) and/or leaves root-owned files inside .git that
    # break a later git operation run as the real owner.
    #
    # The caller's repo_owner argument is trusted when given, but NEVER
    # blindly - if it is empty, or doesn't match the directory's actual
    # on-disk owner (e.g. a misconfigured/empty settings.conf [general]
    # user= at the call site), the directory's REAL owner (stat -c '%U',
    # the same resolution perform_update.sh already uses) wins. This
    # function will refuse to run git as root under any circumstance,
    # even if that means doing nothing on a directory whose owner cannot
    # be determined at all - never silently falls back to running as the
    # current user the way an earlier draft of this function did.
    local disk_owner
    disk_owner="$(stat -c '%U' "${repo_path}" 2>/dev/null)" || disk_owner=""
    if [[ -n "${disk_owner}" && "${disk_owner}" != "root" && "${repo_owner}" != "${disk_owner}" ]]; then
        if [[ -n "${repo_owner}" ]]; then
            echo "⚠ branch_switch: caller-supplied owner '${repo_owner}' does not match ${repo_path}'s actual on-disk owner '${disk_owner}' - using the on-disk owner (never trusting the argument blindly)" >&2
        fi
        repo_owner="${disk_owner}"
    fi

    local as_owner
    if [[ -z "${repo_owner}" || "${repo_owner}" == "root" ]]; then
        echo "⚠ branch_switch: could not determine a non-root owner for ${repo_path} (resolved owner: '${repo_owner:-<empty>}') - refusing to run git as root, skipping" >&2
        _gm_branch_switch_audit_log "switch_skipped_no_safe_owner" "{\"repo_path\": \"${repo_path}\"}"
        return 0
    fi
    as_owner() { sudo -u "${repo_owner}" "$@"; }

    local current_branch
    current_branch="$(as_owner git -C "${repo_path}" rev-parse --abbrev-ref HEAD 2>/dev/null)" || current_branch=""

    if [[ "${current_branch}" == "${GM_BRANCH_SWITCH_TO}" ]]; then
        # Already on the target branch name - fully switched, idempotent
        # no-op. (Deliberately checked before the FROM check below: a
        # station that has already completed the rename has a local
        # branch literally named main, which can never equal
        # GM_BRANCH_SWITCH_FROM anyway, but this makes the no-op
        # explicit and first.)
        return 0
    fi

    if [[ "${current_branch}" != "${GM_BRANCH_SWITCH_FROM}" ]]; then
        # On some OTHER branch entirely (intentionally tracking
        # something that isn't the feature branch, and isn't main) -
        # never touched.
        return 0
    fi

    # From here on: current_branch == GM_BRANCH_SWITCH_FROM. This is
    # EITHER a station never touched by this function before, OR the
    # half-switched state (upstream already repointed to main, local
    # name not yet renamed) - both are finished identically below, the
    # only difference is whether the upstream check further down needs
    # to repoint it or finds it already correct.
    local dirty
    dirty="$(as_owner git -C "${repo_path}" status --porcelain --untracked-files=no 2>&1)" || dirty="git status failed: ${dirty}"
    if [[ -n "${dirty}" ]]; then
        echo "⚠ branch_switch: ${repo_path} is on ${GM_BRANCH_SWITCH_FROM} but the tree is dirty - skipping the switch to ${GM_BRANCH_SWITCH_TO} (never forces past uncommitted/tracked changes). Dirty files: $(printf '%s' "${dirty}" | head -5 | tr '\n' ' ')" >&2
        _gm_branch_switch_audit_log "switch_skipped_dirty_tree" "{\"from\": \"${GM_BRANCH_SWITCH_FROM}\", \"to\": \"${GM_BRANCH_SWITCH_TO}\"}"
        return 0
    fi

    local upstream
    upstream="$(as_owner git -C "${repo_path}" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" || upstream=""
    if [[ "${upstream}" == "origin/${GM_BRANCH_SWITCH_TO}" ]]; then
        echo "branch_switch: ${repo_path} is on local branch ${GM_BRANCH_SWITCH_FROM} but its upstream is ALREADY origin/${GM_BRANCH_SWITCH_TO} (half-switched state) - finishing the rename..."
    else
        echo "branch_switch: ${repo_path} is on ${GM_BRANCH_SWITCH_FROM} (a strict ancestor of ${GM_BRANCH_SWITCH_TO}) and the tree is clean - switching to ${GM_BRANCH_SWITCH_TO}..."
    fi

    if ! as_owner git -C "${repo_path}" fetch origin "${GM_BRANCH_SWITCH_TO}" 2>&1; then
        echo "⚠ branch_switch: fetch of origin/${GM_BRANCH_SWITCH_TO} failed - skipping the switch, will retry on the next run" >&2
        _gm_branch_switch_audit_log "switch_failed_fetch" "{\"from\": \"${GM_BRANCH_SWITCH_FROM}\", \"to\": \"${GM_BRANCH_SWITCH_TO}\"}"
        return 0
    fi

    # GeoMaxima - 2026-10-14 review fix: actually rename the local
    # branch, not just repoint its upstream. `git checkout -B main
    # origin/main` creates (or resets, if it somehow already exists) a
    # local branch literally named main, points it at origin/main,
    # checks it out, and sets its upstream - one atomic-enough step that
    # replaces the old branch -u + reset --hard pair. This is what makes
    # every OTA-path script's `git rev-parse --abbrev-ref HEAD` (the
    # LOCAL branch name) resolve correctly on the very next run, without
    # depending on each of those call sites remembering to check @{u}
    # first (several of them now do, as a second line of defense, but
    # this function should not rely on that).
    local checkout_out checkout_rc
    checkout_out="$(as_owner git -C "${repo_path}" checkout -B "${GM_BRANCH_SWITCH_TO}" "origin/${GM_BRANCH_SWITCH_TO}" 2>&1)" && checkout_rc=0 || checkout_rc=$?
    if [[ "${checkout_rc}" -ne 0 ]]; then
        echo "⚠ branch_switch: git checkout -B ${GM_BRANCH_SWITCH_TO} origin/${GM_BRANCH_SWITCH_TO} failed (exit ${checkout_rc}): ${checkout_out}" >&2
        _gm_branch_switch_audit_log "switch_failed_checkout" "{\"from\": \"${GM_BRANCH_SWITCH_FROM}\", \"to\": \"${GM_BRANCH_SWITCH_TO}\", \"exit\": ${checkout_rc}}"
        return 0
    fi

    # Delete the old LOCAL branch name (never the remote - this function
    # never touches origin/feature/armbian-opi4pro-support). `-D` (not
    # `-d`) because the old branch is, by definition, a strict ancestor
    # of where we just moved to - a plain `-d` would already succeed in
    # that case, but `-D` is used defensively since this isn't git's own
    # safety check to rely on for a branch we're intentionally retiring.
    # Best-effort: a failure here leaves a harmless unused local branch
    # name behind, never blocks the switch itself (already complete by
    # this point).
    as_owner git -C "${repo_path}" branch -D "${GM_BRANCH_SWITCH_FROM}" 2>&1 || true

    local new_head
    new_head="$(as_owner git -C "${repo_path}" rev-parse HEAD 2>/dev/null)" || new_head="unknown"
    echo "✓ branch_switch: ${repo_path} is now on local branch ${GM_BRANCH_SWITCH_TO}, tracking origin/${GM_BRANCH_SWITCH_TO}, at ${new_head:0:7}"
    _gm_branch_switch_audit_log "switch_completed" "{\"from\": \"${GM_BRANCH_SWITCH_FROM}\", \"to\": \"${GM_BRANCH_SWITCH_TO}\", \"new_head\": \"${new_head}\"}"
    return 0
}
