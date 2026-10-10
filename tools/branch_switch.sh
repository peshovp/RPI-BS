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
#   - Idempotent: a station already tracking main (or any other branch)
#     is a silent no-op.
#
# Called from BOTH tools/post_update.sh (for every station after a
# normal OTA, where the hand-off runs) AND web_app/server.py's startup
# self-heal (for a station whose CURRENT perform_update.sh predates the
# post_update.sh hand-off entirely - confirmed true for the Orange Pi 4
# Pro station, still on the 68c61fe perform_update.sh, which has no
# knowledge of post_update.sh at all). Mirrors the existing OTA pull
# logic exactly: `git branch -u` to repoint tracking, then
# `git reset --hard origin/main` (not a merge/rebase) to land the new
# tree, matching perform_update.sh's own reset step.
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

    if [[ "${current_branch}" != "${GM_BRANCH_SWITCH_FROM}" ]]; then
        # Not tracking the old feature branch (already on main, or
        # intentionally tracking something else) - nothing to do.
        return 0
    fi

    local dirty
    dirty="$(as_owner git -C "${repo_path}" status --porcelain --untracked-files=no 2>&1)" || dirty="git status failed: ${dirty}"
    if [[ -n "${dirty}" ]]; then
        echo "⚠ branch_switch: ${repo_path} is tracking ${GM_BRANCH_SWITCH_FROM} but the tree is dirty - skipping the switch to ${GM_BRANCH_SWITCH_TO} (never forces past uncommitted/tracked changes). Dirty files: $(printf '%s' "${dirty}" | head -5 | tr '\n' ' ')" >&2
        _gm_branch_switch_audit_log "switch_skipped_dirty_tree" "{\"from\": \"${GM_BRANCH_SWITCH_FROM}\", \"to\": \"${GM_BRANCH_SWITCH_TO}\"}"
        return 0
    fi

    echo "branch_switch: ${repo_path} is tracking ${GM_BRANCH_SWITCH_FROM} (a strict ancestor of ${GM_BRANCH_SWITCH_TO}) and the tree is clean - switching to ${GM_BRANCH_SWITCH_TO}..."

    if ! as_owner git -C "${repo_path}" fetch origin "${GM_BRANCH_SWITCH_TO}" 2>&1; then
        echo "⚠ branch_switch: fetch of origin/${GM_BRANCH_SWITCH_TO} failed - skipping the switch, will retry on the next run" >&2
        _gm_branch_switch_audit_log "switch_failed_fetch" "{\"from\": \"${GM_BRANCH_SWITCH_FROM}\", \"to\": \"${GM_BRANCH_SWITCH_TO}\"}"
        return 0
    fi

    # Repoint the local branch's upstream - same effect as `git checkout
    # main` but without changing the checked-out branch NAME (the station
    # is still "on" a local branch called feature/armbian-opi4pro-
    # support, now tracking origin/main) - this mirrors the fact that the
    # normal OTA path only ever does a fetch+reset against whatever
    # branch name is currently checked out, never a checkout of a
    # DIFFERENT local branch name, so no other part of the OTA pipeline
    # needs to change for this to work on the very next OTA.
    if ! as_owner git -C "${repo_path}" branch -u "origin/${GM_BRANCH_SWITCH_TO}" 2>&1; then
        echo "⚠ branch_switch: could not repoint the local branch's upstream to origin/${GM_BRANCH_SWITCH_TO} - skipping" >&2
        _gm_branch_switch_audit_log "switch_failed_set_upstream" "{\"from\": \"${GM_BRANCH_SWITCH_FROM}\", \"to\": \"${GM_BRANCH_SWITCH_TO}\"}"
        return 0
    fi

    local reset_out reset_rc
    reset_out="$(as_owner git -C "${repo_path}" reset --hard "origin/${GM_BRANCH_SWITCH_TO}" 2>&1)" && reset_rc=0 || reset_rc=$?
    if [[ "${reset_rc}" -ne 0 ]]; then
        echo "⚠ branch_switch: git reset --hard origin/${GM_BRANCH_SWITCH_TO} failed (exit ${reset_rc}): ${reset_out}" >&2
        _gm_branch_switch_audit_log "switch_failed_reset" "{\"from\": \"${GM_BRANCH_SWITCH_FROM}\", \"to\": \"${GM_BRANCH_SWITCH_TO}\", \"exit\": ${reset_rc}}"
        return 0
    fi

    local new_head
    new_head="$(as_owner git -C "${repo_path}" rev-parse HEAD 2>/dev/null)" || new_head="unknown"
    echo "✓ branch_switch: ${repo_path} now tracks origin/${GM_BRANCH_SWITCH_TO} at ${new_head:0:7}"
    _gm_branch_switch_audit_log "switch_completed" "{\"from\": \"${GM_BRANCH_SWITCH_FROM}\", \"to\": \"${GM_BRANCH_SWITCH_TO}\", \"new_head\": \"${new_head}\"}"
    return 0
}
