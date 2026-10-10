#!/bin/bash
#This script should be run with a unit service and a unit timer
#You can customize archive_rotate in settings.conf
#
# INCIDENT (2026-10-05, test station): every raw archive for several days
# was deleted, timed with a 04:00 rtkbase_archive.timer run. Root cause
# of THAT specific event is UNPROVEN - settings.conf is never tracked in
# git (it's a per-station runtime file), so there is no historical record
# of what archive_rotate/min_free_space/datadir actually were in the
# pre-OTA settings.conf at the moment of the incident, and the math on
# the file as it exists NOW (archive_rotate=60, rewritten by an OTA AFTER
# the incident) rules out an age-based explanation using that value (a
# 60-day cutoff on 2026-10-05 is 2026-08-06 - every file actually deleted
# was weeks newer than that, however this script's own age logic is
# written). Do not assume the pre-incident value was different; it is
# simply unknown.
#
# What IS confirmed, independently of the incident's own root cause, by
# directly testing this script's old behaviour in a temp directory this
# session: this script was unsafe BY CONSTRUCTION regardless of what
# caused this specific incident. It used to
# `source <( grep '=' settings.conf )`, pulling EVERY key from EVERY
# section of an INI file into the shell's variable namespace with zero
# validation, then interpolated archive_rotate/datadir/min_free_space
# directly into `find`/`cd` with no check that they were sane.
# Confirmed, exactly, by direct testing (NOT by inspection alone):
#   - archive_rotate="" (empty)   -> `find -mtime +` is a SYNTAX ERROR,
#     deletes NOTHING, exits 1. Safe by accident, not by design.
#   - archive_rotate="abc"        -> same: syntax error, deletes nothing.
#   - archive_rotate="0" or "00"  -> `find -mtime +0` matches every file
#     at least 1 day old - genuinely deletes EVERYTHING in datadir
#     regardless of real age. This is the one confirmed-destructive value.
# A literal 0/00 is therefore the only confirmed way this OLD script
# could produce the incident's exact symptom (multiple days of zips gone
# in one run) - but whether archive_rotate ever actually held that value
# on this station is unproven (see above). This rewrite closes the
# vulnerability class regardless: explicit, validated parsing of only
# the keys actually needed, and it now REFUSES TO DELETE ANYTHING (while
# still archiving, if datadir is valid) rather than ever reaching a
# destructive `find -delete` with an unvalidated value.
#
# archive_name is NO LONGER read from settings.conf (it was always a
# shell command-substitution string there, evaluated only because the
# old `source <(grep ...)` pattern executed the whole file as code - the
# exact pattern this rewrite removes). The filename FORMAT is UNCHANGED:
# `$(date -d "-1 days" +"%Y-%m-%d_%S").zip` - same as
# settings.conf.default has always had it, computed directly below
# instead of via settings.conf. Readers of this filename format
# (confirmed unaffected, nothing else parses archive_name out of
# settings.conf - grep across the repo found only this script and
# RTKBaseConfigManager.py's NON_QUOTED_KEYS list, which doesn't shape the
# name): web_app/LogManager.py (lists whatever *.zip files exist by
# glob, not by re-deriving the name) and
# addons/features/auto_survey/rtkbase_config.py's get_data_files_since()
# (same - lists and date-sorts whatever is on disk). A leftover
# archive_name= line in an existing settings.conf is harmless and
# ignored (logged once, not an error).

set -u

BASEDIR=$(dirname "$0")
SETTINGS_FILE="${BASEDIR}/settings.conf"
AUDIT_LOG_PATH="/var/lib/rtkbase/audit.log"

# Append a JSON-line audit event in the SAME format/path web_app's
# audit_logger.log_event() uses - so an event from THIS script shows up
# in the same Audit Log tab (web_app/templates/logs.html) as every other
# destructive/notable action the web app logs, instead of only in the
# journal (which the 2026-10-05 incident found has no guaranteed
# retention - see tools/install.sh's install_journald_retention()).
# Best-effort for the SCRIPT's own behaviour (a logging failure must
# never block or alter what this script actually does) - but NEVER
# silent: if the audit.log write itself fails (confirmed live: it is
# root:root 0644 by default, unwritable by this service's own User= -
# see unit/rtkbase_archive.service's ReadWritePaths and
# tools/install.sh's install_audit_log_access() for the real fix - this
# fallback exists for whenever that fix hasn't run yet, or any other
# write failure), the message ALWAYS also goes to the journal (via
# `logger`, at user.crit so it's impossible to miss in `journalctl -p
# crit`) and to this script's own stderr - unlike the old
# `2>/dev/null`-everywhere version, which could lose an audit event with
# zero trace anywhere.
_audit_log() {
  local event="$1" severity="$2" message="$3"
  local ts write_err
  ts=$(date -u +"%Y-%m-%dT%H:%M:%S.%6N")
  mkdir -p "$(dirname "${AUDIT_LOG_PATH}")" 2>/dev/null
  # GeoMaxima - 2026-10-06/07 review fix: NO temp file for the error
  # capture - the previous version redirected stderr to
  # /tmp/.archive_and_clean_audit_err.$$, which itself fails under
  # rtkbase_archive.service's real sandbox (ProtectSystem=strict with no
  # PrivateTmp=yes and /tmp not in ReadWritePaths makes /tmp read-only
  # for this unit). When a redirection target itself can't be opened,
  # bash does not run the command AT ALL - so printf never even
  # attempted the real audit-log write, silently defeating this whole
  # fallback under the exact sandbox it needs to work in. Fixed by
  # capturing output via command substitution + a brace group instead -
  # `$( { cmd; } 2>&1 )` needs no filesystem path at all.
  write_err=$( { printf '{"timestamp": "%s", "category": "archive_and_clean", "event": "%s", "details": {"severity": "%s", "message": "%s"}}\n' \
    "${ts}" "${event}" "${severity}" "${message}" >> "${AUDIT_LOG_PATH}"; } 2>&1 )
  if [[ -n "${write_err}" ]]; then
    echo "archive_and_clean.sh: AUDIT LOG WRITE FAILED (${write_err}) - event: [${event}] ${message}" >&2
    logger -t archive_and_clean -p user.crit "AUDIT LOG WRITE FAILED - event: [${event}] severity=${severity} ${message}"
  fi
}

if [[ ! -f "${SETTINGS_FILE}" ]]; then
  msg="${SETTINGS_FILE} not found - refusing to run"
  echo "archive_and_clean.sh: ${msg}" >&2
  _audit_log "refused" "critical" "${msg}"
  exit 1
fi

# Read exactly the keys this script needs, by exact key name, from the
# [local_storage] section only - never sources the whole file, never
# touches any other section's keys. configparser-written values look
# like key='value' or key=value (single-quoted or bare) - strip
# surrounding single quotes explicitly rather than relying on a shell
# `source` to do it as a side effect.
_read_setting() {
  local key="$1"
  local line
  line=$(grep -E "^${key}=" "${SETTINGS_FILE}" | tail -n1)
  line="${line#${key}=}"
  if [[ "${line}" == \'*\' ]]; then
    line="${line:1:-1}"
  fi
  printf '%s' "${line}"
}

datadir_raw=$(_read_setting "datadir")
archive_rotate=$(_read_setting "archive_rotate")
min_free_space=$(_read_setting "min_free_space")

# archive_name: a DYNAMIC value by design (see the header comment above)
# - computed directly here, same format as settings.conf.default has
# always specified, never read from the file.
archive_name=$(date -d "-1 days" +"%Y-%m-%d_%S").zip

if grep -qE "^archive_name=" "${SETTINGS_FILE}"; then
  echo "archive_and_clean.sh: settings.conf has an archive_name= entry - no longer used, ignoring it (filename is now computed directly: ${archive_name})"
fi

# $BASEDIR expansion is the one legitimate piece of shell substitution
# settings.conf.default's own datadir/logdir values rely on - do it
# explicitly here instead of letting a sourced subshell interpret it.
datadir="${datadir_raw/\$BASEDIR/${BASEDIR}}"

# --- datadir must be valid before ANYTHING else (including the zip
# step) can run - there is no safe partial behaviour without it.
if [[ -z "${datadir}" ]]; then
  msg="datadir is empty in ${SETTINGS_FILE} - refusing to run"
  echo "archive_and_clean.sh: ${msg}" >&2
  _audit_log "refused" "critical" "${msg}"
  exit 1
fi
if [[ ! -d "${datadir}" ]]; then
  msg="datadir '${datadir}' does not exist - refusing to run"
  echo "archive_and_clean.sh: ${msg}" >&2
  _audit_log "refused" "critical" "${msg}"
  exit 1
fi
# Resolve to an absolute path BEFORE cd-ing into it - check_space() below
# calls `df -mP "${datadir}"` from inside datadir itself; a relative
# datadir (e.g. "./data") would silently stop resolving once the script
# has already cd'ed there, breaking the free-space check (confirmed in
# testing this session - df reported "No such file or directory" and
# check_space() returned nothing, which made the free-space loop keep
# deleting files indefinitely instead of stopping once enough space was
# freed - fixed here, and separately bounded below regardless).
datadir=$(cd "${datadir}" && pwd) || {
  msg="cannot cd into datadir '${datadir}' - refusing to run"
  echo "archive_and_clean.sh: ${msg}" >&2
  _audit_log "refused" "critical" "${msg}"
  exit 1
}
cd "${datadir}" || {
  msg="cannot cd into resolved datadir '${datadir}' - refusing to run (aborting before any find/rm)"
  echo "archive_and_clean.sh: ${msg}" >&2
  _audit_log "refused" "critical" "${msg}"
  exit 1
}

# --- archive_rotate/min_free_space validity. UNLIKE datadir, an invalid
# value here does NOT stop the whole script - archiving (compressing
# today's raw files into a zip) is independent of, and safe regardless
# of, retention/free-space settings being wrong. Only DELETION is gated
# on these being valid - per requirement, invalid retention config must
# never silently skip archiving, and must never silently skip deletion
# either: it logs + alerts (Audit Log) every time it refuses to delete.
# GeoMaxima - 2026-10-07 review fix: ^[0-9]+$ accepts a leading zero
# like "08" - which then CRASHES the (( ... < N )) arithmetic
# comparison below, since bash arithmetic treats a leading-zero numeral
# as OCTAL, and "08" is not a valid octal digit string. Confirmed by
# direct testing: `archive_rotate="08"` made `(( archive_rotate < 14
# ))` fail with "value too great for base" instead of cleanly
# evaluating true/false. Fixed the same way as server.py's own
# (already-corrected) validation: ^[1-9][0-9]*$ rejects any leading
# zero outright - a value this script would reject as invalid anyway
# (settings.conf is never expected to contain a leading-zero integer -
# ConfigParser round-trips "60" as "60", never "060").
ARCHIVE_ROTATE_MIN_DAYS=14
archive_rotate_valid=1
if [[ ! "${archive_rotate}" =~ ^[1-9][0-9]*$ ]]; then
  msg="archive_rotate '${archive_rotate}' in ${SETTINGS_FILE} is not a positive integer without a leading zero - deletion DISABLED this run (archiving still proceeds)"
  echo "archive_and_clean.sh: ${msg}" >&2
  _audit_log "deletion_skipped" "critical" "${msg}"
  archive_rotate_valid=0
elif (( 10#${archive_rotate} < ARCHIVE_ROTATE_MIN_DAYS )); then
  msg="archive_rotate=${archive_rotate} is below the ${ARCHIVE_ROTATE_MIN_DAYS}-day retention floor (Инструкция № РД-02-20-25/2011, Чл.57 raw-data retention) - deletion DISABLED this run (archiving still proceeds)"
  echo "archive_and_clean.sh: ${msg}" >&2
  _audit_log "deletion_skipped" "critical" "${msg}"
  archive_rotate_valid=0
fi

min_free_space_valid=1
if [[ ! "${min_free_space}" =~ ^[1-9][0-9]*$ ]]; then
  msg="min_free_space '${min_free_space}' in ${SETTINGS_FILE} is not a positive integer without a leading zero - low-space cleanup DISABLED this run"
  echo "archive_and_clean.sh: ${msg}" >&2
  _audit_log "deletion_skipped" "critical" "${msg}"
  min_free_space_valid=0
fi

check_space(){
  df -mP "${datadir}" | tail -n1 | awk '{ print $4 }'
}

# Free-space loop: delete the oldest ARCHIVE (*.zip) first - lexically
# smallest name, since this project's filenames are date-prefixed, so
# lexical order IS age order - until there's enough free space.
#
# Deliberately restricted to *.zip only (the original version considered
# ANY file, including raw, not-yet-archived *.obs/*.ubx/etc - tightened
# after the incident investigation: this emergency low-space path must
# never touch raw, unarchived data, only already-compressed archives)
# AND to archives already older than the retention floor (archive_rotate
# days) - this loop frees space under disk-full pressure, it must never
# become a second, unbounded way to delete recent data that the
# age-based cleanup below would have refused to touch.
#
# BOUNDED: capped at a fixed maximum iteration count (one per file that
# could plausibly exist) so a bug in check_space() (e.g. datadir
# resolving wrong again in the future) can never turn this into an
# infinite loop - confirmed by direct testing that the ORIGINAL script's
# equivalent loop had no such bound and no stopping condition for a
# persistently-failing check_space().
if [[ "${min_free_space_valid}" -eq 1 && "${archive_rotate_valid}" -eq 1 ]]; then
  _max_free_space_iterations=10000
  _iter=0
  # 10# forces base-10 interpretation defensively - min_free_space is
  # already validated above to never have a leading zero, and
  # check_space()'s own `df` output is a plain decimal MB count that
  # never zero-pads in practice, but this is the same class of bug
  # (( [[ -lt ]] crashes on a leading-zero operand exactly like (( ))
  # does, confirmed by direct testing) and costs nothing to guard
  # against unconditionally.
  while [[ "$(check_space)" -lt "10#${min_free_space}" ]]
  do
    _iter=$((_iter + 1))
    if (( _iter > _max_free_space_iterations )); then
      msg="low free space (<${min_free_space}MB) cleanup hit its ${_max_free_space_iterations}-iteration safety cap - stopping (this should never happen; check_space()/datadir may be misbehaving)"
      echo "archive_and_clean.sh: ${msg}" >&2
      _audit_log "deletion_skipped" "critical" "${msg}"
      break
    fi
    file_to_delete=$(find . -maxdepth 1 -type f -name "*.zip" -mtime "+${archive_rotate}" | sort -r | tail -1)
    if [[ -z ${file_to_delete} ]]
    then
      msg="low free space (<${min_free_space}MB) but no archive older than the ${archive_rotate}-day retention floor is left to delete - stopping (raw/.obs files are NEVER deleted by this loop)"
      echo "archive_and_clean.sh: ${msg}" >&2
      _audit_log "deletion_skipped" "critical" "${msg}"
      break
    fi
    file_size=$(stat -c '%s' "${file_to_delete}" 2>/dev/null || echo '?')
    file_age_days=$(( ( $(date +%s) - $(stat -c '%Y' "${file_to_delete}" 2>/dev/null || date +%s) ) / 86400 ))
    msg="low free space (<${min_free_space}MB) - deleting ${file_to_delete} (${file_size} bytes, ${file_age_days} days old)"
    echo "archive_and_clean.sh: ${msg}"
    _audit_log "low_free_space_delete" "info" "${msg}"
    if ! rm -f "${file_to_delete}"
    then
      break
    fi
  done
fi


#archive and compress previous day's gnss data. Runs regardless of
#archive_rotate/min_free_space validity - archiving is independent of
#retention/free-space settings.
find . -maxdepth 1 -type f -mtime -960 -mmin +60 \( -name "*.rtcm*" -o -name "*.nov*" -o -name "*.oem*" -o -name "*.ubx*" -o -name "*.ss2*" -o -name "*.hemis*" -o -name "*.stq*" -o -name "*.javad*" -o -name "*.nvs*" -o -name "*.binex*" -o -name "*.sbf*" \) -exec zip -m9 "${archive_name}" {} +;

#delete gnss data older than archive_rotate days - ONLY if archive_rotate
#was validated above. Every deletion logged to both the journal and
#audit.log (name, size, age) so a future incident is diagnosable without
#relying on the journal's own (now also fixed) retention alone.
if [[ "${archive_rotate_valid}" -eq 1 ]]; then
  while IFS= read -r -d '' f; do
    file_size=$(stat -c '%s' "${f}" 2>/dev/null || echo '?')
    file_age_days=$(( ( $(date +%s) - $(stat -c '%Y' "${f}" 2>/dev/null || date +%s) ) / 86400 ))
    msg="deleting ${f} (${file_size} bytes, ${file_age_days} days old, retention=${archive_rotate} days)"
    echo "archive_and_clean.sh: ${msg}"
    _audit_log "age_based_delete" "info" "${msg}"
    rm -f "${f}"
  done < <(find . -maxdepth 1 -type f -name "*.zip" -mtime "+${archive_rotate}" -print0)
fi
