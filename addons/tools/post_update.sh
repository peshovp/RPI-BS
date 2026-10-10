#!/bin/bash
#
# Post-update steps - run AFTER perform_update.sh's own `git reset
# --hard` has landed the new tree, invoked from a FRESH COPY of THIS
# script (made after the reset, not perform_update.sh's own pre-reset
# self-copy) so every step here always comes from the version just
# pulled, never from whatever perform_update.sh version happened to
# launch the update.
#
# GeoMaxima - 2026-10-10/13 review fix: confirmed live that an OTA to
# commit fccc038 did NOT apply install_audit_log_access()/
# install_journald_retention()/the service-state restore at all, even
# though all three were already committed. Root cause: perform_update.sh
# makes a private self-copy of ITSELF to /tmp BEFORE the git reset
# (exactly so `git reset` replacing the on-disk file mid-run can't
# corrupt the running script), and
# addons/features/ota_update/update_controller.py's perform_update()
# resolves `update_script` and launches it BEFORE any git pull/reset -
# so the running process is always whichever perform_update.sh version
# was on disk at the START of the OTA, which can never see its own
# post-reset code no matter how that script is edited internally. The
# fix is structural: this is now a SEPARATE script, invoked via a
# fresh `bash -c "$(cat tools/post_update.sh)"`-style re-read (see
# perform_update.sh's own call site) taken from disk AFTER the reset
# has already landed, so it is always the version that was just pulled.
#
# Idempotent and safe to re-run - every step here just re-applies the
# same end state (ownership/mode, drop-in file, service active/enabled
# state) regardless of the station's current state.
#
# GeoMaxima - 2026-10-13 review fix: this script must ALWAYS exit 0, no
# matter what happens inside it. perform_update.sh's hand-off
# (`cat tools/post_update.sh | bash -s -- ...`) is already wrapped in an
# `if ... ; then ... ; else ...warn...; fi` on BOTH the already-committed
# 298cedb version (which will launch the very next OTA on the station
# this incident happened on) and the current version in this repo - so a
# non-zero exit here was already caught and turned into a warning rather
# than aborting the parent before it reaches the service-state restore/
# web restart. This exit-0 guarantee is a second, independent line of
# defense against the still-unexplained "exit 3" seen live: even if some
# future change to this script (or an environment this hasn't been
# tested against) introduces a path that would otherwise propagate a
# nonzero exit, that can never again reach the parent and abort it.
# Implemented via a trap on EXIT that forces exit 0 unconditionally,
# covering every path out of this script - explicit exit calls, `set -u`
# unbound-variable aborts, and signals - not just the normal fall-through
# at the bottom.
trap 'exit 0' EXIT

set -u

DEV_REPO_PATH="${1:?Repo path argument required}"
REPO_OWNER="${2:?Repo owner argument required}"
GEOMAXIMA_RUN_ID="${3:-}"

AUDIT_LOG="/var/lib/rtkbase/audit.log"
_post_update_audit_log() {
  local event="$1" details_json="$2"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%S.%6N")
  mkdir -p "$(dirname "${AUDIT_LOG}")" 2>/dev/null
  local err
  err=$( { printf '{"timestamp": "%s", "category": "post_update", "event": "%s", "details": %s}\n' \
    "${ts}" "${event}" "${details_json}" >> "${AUDIT_LOG}"; } 2>&1 )
  if [[ -n "${err}" ]]; then
    echo "post_update.sh: AUDIT LOG WRITE FAILED (${err}) - event: [${event}] ${details_json}" >&2
    logger -t post_update -p user.crit "AUDIT LOG WRITE FAILED - event: [${event}] ${details_json}" 2>/dev/null
  fi
}

echo "=========================================="
echo "POST-UPDATE STEPS STARTED: $(date)"
echo "=========================================="

if [[ -x "${DEV_REPO_PATH}/tools/install.sh" ]]; then
  echo "post_update.sh: running install_audit_log_access..."
  if sudo "${DEV_REPO_PATH}/tools/install.sh" --audit-log-access --user "${REPO_OWNER}" 2>&1; then
    _post_update_audit_log "audit_log_access_applied" "{\"user\": \"${REPO_OWNER}\"}"
  else
    echo "⚠ install_audit_log_access reported an error - continuing anyway" >&2
    _post_update_audit_log "audit_log_access_failed" "{\"user\": \"${REPO_OWNER}\"}"
  fi

  echo "post_update.sh: running install_journald_retention..."
  if sudo "${DEV_REPO_PATH}/tools/install.sh" --journald-retention --user "${REPO_OWNER}" 2>&1; then
    _post_update_audit_log "journald_retention_applied" "{}"
  else
    echo "⚠ install_journald_retention reported an error - continuing anyway" >&2
    _post_update_audit_log "journald_retention_failed" "{}"
  fi
else
  echo "⚠ tools/install.sh not found/executable - skipping audit-log-access/journald-retention" >&2
fi

# Service-state snapshot/restore - same logic as perform_update.sh's
# own copy (duplicated here deliberately: this script's whole reason
# to exist is to be independent of perform_update.sh's own version at
# launch time, so it must not depend on sourcing anything from that
# script either).
GEOMAXIMA_SERVICE_STATE_FILE="/var/lib/rtkbase/.post_update_service_state"
GEOMAXIMA_PRE_SHUTDOWN_SNAPSHOT="/var/lib/rtkbase/ota/service_state_before.json"
GEOMAXIMA_SNAPSHOT_MAX_AGE_SECONDS=1800
mkdir -p "$(dirname "${GEOMAXIMA_SERVICE_STATE_FILE}")" 2>/dev/null

_post_update_service_units() {
  systemctl list-unit-files --no-legend 2>/dev/null \
    | awk '{print $1}' \
    | grep -E '^(str2str_|rtkbase_|geomaxima_)[^@]*\.(service|timer)$' \
    | sort -u
}

_used_pre_shutdown_snapshot=0
if [[ -r "${GEOMAXIMA_PRE_SHUTDOWN_SNAPSHOT}" ]] && [[ -n "${GEOMAXIMA_RUN_ID}" ]] && command -v python3 >/dev/null 2>&1; then
  if python3 - "${GEOMAXIMA_PRE_SHUTDOWN_SNAPSHOT}" "${GEOMAXIMA_SERVICE_STATE_FILE}" "${GEOMAXIMA_RUN_ID}" "${GEOMAXIMA_SNAPSHOT_MAX_AGE_SECONDS}" << 'PYEOF'
import json, sys
from datetime import datetime, timezone
snapshot_path, out_path, expected_run_id, max_age_seconds = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
try:
    with open(snapshot_path) as f:
        data = json.load(f)
    if data.get("run_id") != expected_run_id:
        sys.exit(1)
    written_at = datetime.fromisoformat(data["timestamp"])
    age_seconds = (datetime.now(timezone.utc) - written_at).total_seconds()
    if age_seconds > max_age_seconds or age_seconds < 0:
        sys.exit(1)
    with open(out_path, "w") as f:
        for unit, state in data.get("units", {}).items():
            f.write(f"{unit} {state.get('active', 'unknown')} {state.get('enabled', 'unknown')}\n")
except (OSError, ValueError, KeyError):
    sys.exit(1)
PYEOF
  then
    _used_pre_shutdown_snapshot=1
    rm -f "${GEOMAXIMA_PRE_SHUTDOWN_SNAPSHOT}" 2>/dev/null
    echo "post_update.sh: using the pre-shutdown service-state snapshot (run_id matched, fresh)"
  else
    echo "post_update.sh: ⚠ pre-shutdown snapshot did not match this run (wrong run_id or too old) - ignoring it" >&2
  fi
fi
if [[ "${_used_pre_shutdown_snapshot}" -eq 0 ]]; then
  echo "post_update.sh: ⚠ no usable pre-shutdown snapshot - taking one now from inside this script (may already be post-shutdown)" >&2
  : > "${GEOMAXIMA_SERVICE_STATE_FILE}"
  while IFS= read -r unit; do
    [[ -z "${unit}" ]] && continue
    active=$(systemctl is-active "${unit}" 2>/dev/null)
    enabled=$(systemctl is-enabled "${unit}" 2>/dev/null)
    echo "${unit} ${active} ${enabled}" >> "${GEOMAXIMA_SERVICE_STATE_FILE}"
  done < <(_post_update_service_units)
fi

_before_json="[" _first=1
while IFS=' ' read -r unit active enabled; do
  [[ -z "${unit}" ]] && continue
  if [[ "${_first}" -eq 1 ]]; then _first=0; else _before_json+=","; fi
  _before_json+="{\"unit\": \"${unit}\", \"active\": \"${active}\", \"enabled\": \"${enabled}\"}"
done < "${GEOMAXIMA_SERVICE_STATE_FILE}"
_before_json+="]"
_source="in_script_fallback"
[[ "${_used_pre_shutdown_snapshot}" -eq 1 ]] && _source="pre_shutdown_snapshot"
_post_update_audit_log "before_update" "{\"source\": \"${_source}\", \"units\": ${_before_json}}"

_after_json="[" _first=1
while read -r unit active enabled; do
  [[ -z "${unit}" ]] && continue
  now_active=$(systemctl is-active "${unit}" 2>/dev/null)
  now_enabled=$(systemctl is-enabled "${unit}" 2>/dev/null)
  if [[ "${active}" == "active" && "${now_active}" != "active" && "${now_active}" != "activating" ]]; then
    echo "post_update.sh: restoring ${unit} to active (was active before this update)"
    systemctl start "${unit}" 2>/dev/null
  fi
  if [[ "${enabled}" == "enabled" && "${now_enabled}" == "disabled" ]]; then
    echo "post_update.sh: restoring ${unit} to enabled (was enabled before this update)"
    systemctl enable "${unit}" 2>/dev/null
  fi
  now_active=$(systemctl is-active "${unit}" 2>/dev/null)
  now_enabled=$(systemctl is-enabled "${unit}" 2>/dev/null)
  if [[ "${_first}" -eq 1 ]]; then _first=0; else _after_json+=","; fi
  _after_json+="{\"unit\": \"${unit}\", \"active_before\": \"${active}\", \"enabled_before\": \"${enabled}\", \"active_after\": \"${now_active}\", \"enabled_after\": \"${now_enabled}\"}"
done < "${GEOMAXIMA_SERVICE_STATE_FILE}"
_after_json+="]"
_post_update_audit_log "after_update" "${_after_json}"
rm -f "${GEOMAXIMA_SERVICE_STATE_FILE}" 2>/dev/null

echo "post_update.sh: done"
exit 0
