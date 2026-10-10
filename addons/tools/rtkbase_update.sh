#!/bin/bash
### THIS SCRIPT SHOULD NOT BE RUN MANUALLY ###

#'shopt -s extglob' is needed for using (!pattern) exclusion pattern
#from inside a script
shopt -s extglob

#enable this line to send the script output to /var/log/syslog.
#exec 1> >(logger -s -t $(basename $0)) 2>&1

source_directory=$1
destination_directory=$2
data_dir=$3
old_version=$4
standard_user=$5
checking=$6
# GeoMaxima - 2026-10-07 review fix: run_id, matched against the
# pre-shutdown snapshot's own run_id (see
# addons/ota_service_snapshot.py) so a STALE snapshot from an unrelated
# or previous run can never be mistaken for this run's pre-update state.
# Optional - empty during the --checking dry-run call (which never
# reaches the snapshot-reading code below) and for any older/manual
# caller that doesn't pass it, in which case the snapshot is never
# trusted and this script always falls back to its own in-script
# snapshot (logged as such).
geomaxima_run_id=${7:-}

#argument checking
[[ -d "${source_directory}" ]] || { echo 'ERROR! source_directory is not a directory'; exit 1; }
[[ -d "${destination_directory}" ]] || { echo 'ERROR! destination_directory is not a directory'; exit 1; }
#[[ -d "${data_dir}" ]] || { echo 'ERROR! data_dir is not a directory'; exit 1; } <- not a full path directory, just the directory name
#[[ "${old_version}" =~ ^[+-]?[0-9]+\.?[0-9]*$ ]] || { echo 'ERROR! wrong type for current_version variable'; exit 1; } <- doesn't work for 2.5.0 or 2.4b
[[ $(id -u "${standard_user}") ]] &>/dev/null || { echo 'ERROR! user does not exist'; exit 1; }
# $checking variable doesn't need to be checked as it is used only if it is set to '--checking'

#store service status before upgrade
str2str_active=$(systemctl is-active str2str_tcp)
str2str_ntrip_A_active=$(systemctl is-active str2str_ntrip_A)
str2str_ntrip_B_active=$(systemctl is-active str2str_ntrip_B)
str2str_local_caster=$(systemctl is-active str2str_local_ntrip_caster)
str2str_rtcm=$(systemctl is-active str2str_rtcm_svr)
str2str_serial=$(systemctl is-active str2str_rtcm_serial)
str2str_file=$(systemctl is-active str2str_file)
rtkrcv_raw2nmea=$(systemctl is-active rtkbase_raw2nmea)

# GeoMaxima - 2026-10-05 archive incident fix: a GENERIC, exhaustive
# before/after service-state snapshot, covering every rtkbase/str2str/
# geomaxima_* service (not just the 8 hand-picked above, which the
# incident investigation found had str2str_file's own RESTORE step
# commented out further down - a hand-maintained list is exactly the
# kind of thing that silently drifts). Records BOTH is-active AND
# is-enabled for every matching unit (an OTA must preserve "disabled but
# was running" and "enabled but was stopped" just as faithfully as the
# common "was running" case), and logs the full before/after pair to
# audit.log so a station's service state across an OTA is always
# reconstructable afterward - the gap that made the 2026-10-05
# incident's own File-service outage take 4+ days to even notice.
GEOMAXIMA_AUDIT_LOG="/var/lib/rtkbase/audit.log"
_geomaxima_audit_log() {
  local event="$1" details_json="$2"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%S.%6N")
  mkdir -p "$(dirname "${GEOMAXIMA_AUDIT_LOG}")" 2>/dev/null
  printf '{"timestamp": "%s", "category": "ota_service_state", "event": "%s", "details": %s}\n' \
    "${ts}" "${event}" "${details_json}" >> "${GEOMAXIMA_AUDIT_LOG}" 2>/dev/null
}

# GeoMaxima - 2026-10-07 review fix: covers .timer units too (e.g.
# rtkbase_archive.timer), not just .service - an OTA's own unit-file
# redeploy (copy_unit.sh) can affect either.
_geomaxima_service_units() {
  systemctl list-unit-files --no-legend 2>/dev/null \
    | awk '{print $1}' \
    | grep -E '^(str2str_|rtkbase_|geomaxima_)[^@]*\.(service|timer)$' \
    | sort -u
}

GEOMAXIMA_SERVICE_STATE_FILE="/var/lib/rtkbase/.ota_service_state_before_update"
mkdir -p "$(dirname "${GEOMAXIMA_SERVICE_STATE_FILE}")" 2>/dev/null

# GeoMaxima - 2026-10-05/06 incident investigation: prefer the snapshot
# web_app/server.py's update_rtkbase() or
# addons/features/ota_update/update_controller.py's perform_update()
# already wrote via addons/ota_service_snapshot.py - taken BEFORE this
# script even started (and before any shutdown-adjacent call), so it
# reflects truly pre-update state. Fall back to taking our own snapshot
# here (and logging that it may already be post-shutdown, since this
# script itself starts after the Flask app's own pre-launch steps have
# run) only if that file is missing/unreadable (e.g. a manual/CLI-run
# update with no Flask process involved at all).
GEOMAXIMA_PRE_SHUTDOWN_SNAPSHOT="/var/lib/rtkbase/ota/service_state_before.json"
GEOMAXIMA_SNAPSHOT_MAX_AGE_SECONDS=1800
_geomaxima_used_pre_shutdown_snapshot=0
if [[ -r "${GEOMAXIMA_PRE_SHUTDOWN_SNAPSHOT}" ]] && [[ -n "${geomaxima_run_id}" ]] && command -v python3 >/dev/null 2>&1; then
  # GeoMaxima - 2026-10-07 review fix: the snapshot's raw state strings
  # (active/inactive/failed/activating...; enabled/disabled/static/
  # masked/indirect...) are passed through VERBATIM - no boolean
  # collapsing. Also requires run_id to match AND the snapshot to be
  # younger than GEOMAXIMA_SNAPSHOT_MAX_AGE_SECONDS, so a stale or
  # unrelated-run snapshot is never mistaken for this run's own
  # pre-update state. The snapshot file is deleted after a successful,
  # matching read (one-shot).
  if python3 - "${GEOMAXIMA_PRE_SHUTDOWN_SNAPSHOT}" "${GEOMAXIMA_SERVICE_STATE_FILE}" "${geomaxima_run_id}" "${GEOMAXIMA_SNAPSHOT_MAX_AGE_SECONDS}" << 'PYEOF'
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
            active = state.get("active", "unknown")
            enabled = state.get("enabled", "unknown")
            f.write(f"{unit} {active} {enabled}\n")
except (OSError, ValueError, KeyError):
    sys.exit(1)
PYEOF
  then
    _geomaxima_used_pre_shutdown_snapshot=1
    rm -f "${GEOMAXIMA_PRE_SHUTDOWN_SNAPSHOT}" 2>/dev/null
    echo "rtkbase_update.sh: using the pre-shutdown service-state snapshot from ${GEOMAXIMA_PRE_SHUTDOWN_SNAPSHOT} (run_id matched, fresh)"
  else
    echo "rtkbase_update.sh: pre-shutdown snapshot exists but did not match this run (wrong run_id or too old) - ignoring it" >&2
  fi
fi

if [[ "${_geomaxima_used_pre_shutdown_snapshot}" -eq 0 ]]; then
  echo "rtkbase_update.sh: no usable pre-shutdown snapshot found at ${GEOMAXIMA_PRE_SHUTDOWN_SNAPSHOT} - taking a snapshot now, from INSIDE this script. NOTE: this may already be AFTER whatever launched this script (e.g. the web app) performed its own shutdown/stop steps, so this snapshot's 'before' state is not guaranteed to be the true pre-update state." >&2
  : > "${GEOMAXIMA_SERVICE_STATE_FILE}"
  while IFS= read -r unit; do
    [[ -z "${unit}" ]] && continue
    active=$(systemctl is-active "${unit}" 2>/dev/null)
    enabled=$(systemctl is-enabled "${unit}" 2>/dev/null)
    echo "${unit} ${active} ${enabled}" >> "${GEOMAXIMA_SERVICE_STATE_FILE}"
  done < <(_geomaxima_service_units)
fi

_geomaxima_before_json="["
_geomaxima_first=1
while IFS=' ' read -r unit active enabled; do
  [[ -z "${unit}" ]] && continue
  if [[ "${_geomaxima_first}" -eq 1 ]]; then _geomaxima_first=0; else _geomaxima_before_json+=","; fi
  _geomaxima_before_json+="{\"unit\": \"${unit}\", \"active\": \"${active}\", \"enabled\": \"${enabled}\"}"
done < "${GEOMAXIMA_SERVICE_STATE_FILE}"
_geomaxima_before_json+="]"
_geomaxima_before_json_source="in_script_fallback"
[[ "${_geomaxima_used_pre_shutdown_snapshot}" -eq 1 ]] && _geomaxima_before_json_source="pre_shutdown_snapshot"
_geomaxima_audit_log "before_update" "{\"source\": \"${_geomaxima_before_json_source}\", \"units\": ${_geomaxima_before_json}}"

# Restore every captured unit to EXACTLY its pre-update active AND
# enabled state. Called at the very end of this script (see the bottom)
# once the update itself has finished, so every unit file is already in
# its final, post-update form first.
#
# GeoMaxima - 2026-10-07 review fix: now ALSO restores enabled<->
# disabled (not just active<->inactive) - directly relevant to the
# File-service root cause: survey_controller.py's one-owner handoff
# calls ServiceController.stop() to temporarily stop str2str_file
# between surveys, and that method's upstream semantics are
# DisableUnitFiles + Stop (disable AND stop, not stop alone - see
# ServiceController.py:69-74), so every such handoff was PERMANENTLY
# disabling the service, not just pausing it. This restore now corrects
# that, AND is scoped tightly: it ONLY ever flips the two pairs
# active<->inactive and enabled<->disabled - any other state
# (activating/deactivating/failed for active; static/masked/indirect/
# alias/generated/transient for enabled) is left exactly as found,
# never forced into either pair, and masked units are never unmasked.
_geomaxima_restore_service_states() {
  [[ -f "${GEOMAXIMA_SERVICE_STATE_FILE}" ]] || return 0
  local after_json="["
  local first=1
  while read -r unit active enabled; do
    [[ -z "${unit}" ]] && continue
    local now_active now_enabled
    now_active=$(systemctl is-active "${unit}" 2>/dev/null)
    now_enabled=$(systemctl is-enabled "${unit}" 2>/dev/null)

    if [[ "${active}" == "active" && "${now_active}" != "active" && "${now_active}" != "activating" ]]; then
      echo "rtkbase_update.sh: restoring ${unit} to active (was active before this update, OTA left it ${now_active})"
      systemctl start "${unit}" 2>/dev/null
    elif [[ "${active}" == "inactive" && "${now_active}" == "active" ]]; then
      echo "rtkbase_update.sh: ${unit} is active but was NOT active before this update - leaving it as-is (an OTA must preserve state, not force a service off that something else started)"
    fi

    if [[ "${enabled}" == "enabled" && "${now_enabled}" == "disabled" ]]; then
      echo "rtkbase_update.sh: restoring ${unit} to enabled (was enabled before this update, OTA/a stop-helper's DisableUnitFiles call left it disabled)"
      systemctl enable "${unit}" 2>/dev/null
    elif [[ "${enabled}" == "disabled" && "${now_enabled}" == "enabled" ]]; then
      echo "rtkbase_update.sh: ${unit} is enabled but was NOT enabled before this update - leaving it as-is"
    fi
    # static/masked/indirect/alias/generated/transient (either side):
    # intentionally untouched - no branch above matches them, by design.

    now_active=$(systemctl is-active "${unit}" 2>/dev/null)
    now_enabled=$(systemctl is-enabled "${unit}" 2>/dev/null)
    if [[ "${first}" -eq 1 ]]; then first=0; else after_json+=","; fi
    after_json+="{\"unit\": \"${unit}\", \"active_before\": \"${active}\", \"enabled_before\": \"${enabled}\", \"active_after\": \"${now_active}\", \"enabled_after\": \"${now_enabled}\"}"
  done < "${GEOMAXIMA_SERVICE_STATE_FILE}"
  after_json+="]"
  _geomaxima_audit_log "after_update" "${after_json}"
}

check_before_update() {
  TOO_OLD='<b>Your Operating System is too old!</b>\n
    Please reflash your SDCard with a more recent RTKBase image, or upgrade your OS.\n
    Don'"'"'t forget to backup your settings.\n\n
    <a href="https://github.com/Stefal/rtkbase" target="_blank">RTKBase repository</a>\n\n
    <a href="https://docs.centipede.fr/docs/base/mise_a_jour.html" target="_blank">Documentation CentipedeRTK</a>'

  if [[ -f /etc/os-release ]]
    then
      source /etc/os-release
    else
      printf "Warning! We can't check your Os release, upgrade at your own risk\n"      
  fi

  case $ID in
    debian)
      if (( $(echo "$VERSION_ID < 12" | bc -l) ))
      then
        printf "${TOO_OLD}" >/dev/stderr
        exit 1
      fi
      ;;
    raspbian)
    if (( $(echo "$VERSION_ID < 12" | bc -l) ))
      then
        printf "${TOO_OLD}" >/dev/stderr
        exit 1
      fi
      ;;
    ubuntu)
      if (( $(echo "$VERSION_ID < 24.04" | bc -l) ))
      then
        printf "${TOO_OLD}" >/dev/stderr
        exit 1
      fi
      ;;
  esac
}

update() {
  echo 'remove existing rtkbase.old directory'
  rm -rf /var/tmp/rtkbase.old
  mkdir /var/tmp/rtkbase.old

  echo "copy rtkbase to rtkbase.old except /data directory"
  cp -r ${destination_directory}/!(${data_dir}|venv) /var/tmp/rtkbase.old

  #Don't do that or it will stop the update process
  #systemctl stop rtkbase_web.service

  echo "copy new release to destination"
  if [[ -d ${source_directory} ]] && [[ -d ${destination_directory} ]] 
    then
      cp -rfp ${source_directory}/. ${destination_directory}
    else
      echo 'can t copy'
      exit 1
  fi
}

insert_rtcm_msg() {
# inserting new message inside a rtcm message list
# and "return" the new strings with the ${new_rtcm} global variable
# it will try to insert it a the lowest possible position


    local text_line=${1}
    local msg_to_insert=${2}
    local highest_msg=${3}
    local delay=${4}
    
    new_rtcm=''
    if [[ ! $(echo ${text_line} | grep -q ${msg_to_insert}) ]]
    then
        for (( i=${msg_to_insert}; i<=${highest_msg}; i++ ))
            do
                if [[ $(echo ${text_line} | grep -q $i) ]]
                then
                    echo 'insert '${msg_to_insert}' before '$i
                    new_rtcm=$(echo ${text_line} | sed 's|'"${i}"'|'"${msg_to_insert}${delay}"',&|')
                    echo ${new_rtcm}
                    break
                fi
            done
    else
        #msg already inside the string
        return 1
    fi
 }

upgrade_rtklib() {
  systemctl stop str2str_tcp
  systemctl stop rtkbase_raw2nmea
  bin_path=$(dirname "$(command -v str2str)")
  rm "${bin_path}"'/str2str' "${bin_path}"'/rtkrcv' "${bin_path}"'/convbin'
  "${destination_directory}"'/tools/install.sh' --user "${standard_user}" --rtklib
}

upd_2.4.0() {
  echo '####################'
  echo 'Update from 2.4.0'
  echo '####################'
  upd_2.4.1 "$@"
}

upd_2.4.1() {
  echo '####################'
  echo 'Update from 2.4.1'
  echo '####################'
  upd_2.4.2 "$@"
}

upd_2.4.2() {
  echo '####################'
  echo 'Update from 2.4.2'
  echo '####################'
  apt-get update -y --allow-releaseinfo-change
  apt-get --fix-broken install # needed for old installation (raspi image v2.1 from july 2020)
  # only for Orange Pi Zero, disable sysstats-collect (https://github.com/Stefal/build/issues/14)
  # and update hostapd if error (https://github.com/Stefal/build/issues/15)
  computer_model=$(tr -d '\0' < /sys/firmware/devicetree/base/model)
  sbc_array=('Xunlong Orange Pi Zero')
    if printf '%s\0' "${sbc_array[@]}" | grep -Fxqz -- "${computer_model}"
      then
        echo 'Masking sysstat-collect.timer service and upgrading hostapd'
        systemctl mask sysstat-collect.timer
        dpkg -s hostapd | grep -q 'Version: 2:2.9' && apt-get upgrade -y hostapd
        rm -r /var/log/sysstat/
    fi
  # end of Orange Pi Zero section
  "${destination_directory}"/tools/install.sh --user "${standard_user}" --dependencies --rtkbase-requirements --unit-files
  #upgrade rtklib to b34h
  upgrade_rtklib
  #restart str2str if it was active before upgrading rtklib
  [ $str2str_active = 'active' ] && systemctl start str2str_tcp
  # restart previously running services
  [ $str2str_ntrip_A_active = 'active' ] && systemctl start str2str_ntrip_A
  [ $str2str_ntrip_B_active = 'active' ] && systemctl start str2str_ntrip_B  
  [ $str2str_local_caster = 'active' ] && systemctl start str2str_local_ntrip_caster
  [ $str2str_rtcm = 'active' ] && systemctl start str2str_rtcm_svr
  [ $str2str_serial = 'active' ] && systemctl start str2str_rtcm_serial
  [ $str2str_file = 'active' ] && systemctl start str2str_file
  return 0
}

upd_2.5.0 () {
  # only for Orange Pi Zero, update armbian-ramlog (https://github.com/Stefal/build/issues/16)
  computer_model=$(tr -d '\0' < /sys/firmware/devicetree/base/model)
  sbc_array=('Xunlong Orange Pi Zero')
    if printf '%s\0' "${sbc_array[@]}" | grep -Fxqz -- "${computer_model}" &&
       lsb_release -c | grep -qE 'bullseye|bookworm' &&
       grep -qE 'armbian' /etc/os-release
      then
        echo 'Updating armbian-ramlog'
        sed -i 's/armbian-ramlog)" | while/armbian-ramlog)|\\.journal" | while/' /usr/lib/armbian/armbian-ramlog
    fi
  # end of Orange Pi Zero section
  "${destination_directory}"/tools/install.sh --user "${standard_user}" --dependencies --rtkbase-requirements --unit-files
  "${destination_directory}"/venv/bin/python -m pip uninstall eventlet -y
  #upgrade rtklib to b34j
  upgrade_rtklib
  #remove sbas rtcm message
  sed -i -r '/^rtcm_/s/1107(\([0-9]+\))?,//' "${destination_directory}"/settings.conf

}

upd_2.6.0() {
  echo '##########################'
  echo 'Update from 2.6.0 to 2.6.1'
  echo '##########################'
  # update modem_check_service file (see https://github.com/Stefal/rtkbase/commit/cfad1981e483d74da04f53b8d7b354661100d610)
  "${destination_directory}"/tools/install.sh --user "${standard_user}" --unit-files
  # build rtklib if current release doesn't work
  if  ! str2str --version > /dev/null 2>&1
   then
     "${destination_directory}"/tools/install.sh --user "${standard_user}" --rtklib
  fi
  upd_2.6.1 "$@"
}

upd_2.6.1() {
  echo '##########################'
  echo 'Update from 2.6.1 to 2.6.2'
  echo '##########################'
  #Remove firstboot service from the Raspberry 2.5 and 2.6 images
  #This service should have been removed after the first boot, but
  # wasn't and was stopping various RTKBase services at each boot. 
  if [[ -f /etc/os-release ]]
    then
      source /etc/os-release
  fi

  if [[ $ID == debian ]] && systemctl list-units firstboot.service
    then
      systemctl disable --now firstboot.service
      rm /lib/systemd/system/firstboot.service
      systemctl daemon-reload
  fi
  upd_2.6.2 "$@"
}

upd_2.6.2() {
  echo '##########################'
  echo 'Update from 2.6.2 to 2.6.3'
  echo '##########################'
  #Remove firstboot service from the Raspberry 2.5 and 2.6 images
  #This service should have been removed after the first boot, but
  # wasn't and was stopping various RTKBase services at each boot. 
  if [[ -f /etc/os-release ]]
    then
      source /etc/os-release
  fi

  if [[ $ID == raspbian ]] && systemctl list-units firstboot.service
    then
      systemctl disable --now firstboot.service
      rm /lib/systemd/system/firstboot.service
      systemctl daemon-reload
  fi
  upd_2.6.3 "$@"
}

upd_2.6.3() {
  echo '##########################'
  echo 'Update from 2.6.3 to 2.6.4'
  echo '##########################'
  # install updated service and new avahi service definition (forgot it on the previous update)
  "${destination_directory}"/tools/install.sh --user "${standard_user}" --unit-files --zeroconf
  upd_2.6.4 "$@"
}

upd_2.6.4() {
  echo '##########################'
  echo 'Update from 2.6.4 to 2.7.0'
  echo '##########################'
  # install updated service and new avahi service definition (forgot it on the previous update)
  "${destination_directory}"/tools/install.sh --user "${standard_user}" --unit-files --zeroconf
  # upgrade dependencies
  "${destination_directory}"/tools/install.sh --user "${standard_user}" --dependencies --rtkbase-requirements
  #upgrade rtklib to RTKLib 2.5
  upgrade_rtklib
  
  # Deploy GeoMaxima features to web_app
  echo 'Deploying GeoMaxima features...'
  if [[ -d "${destination_directory}/geomaxima" ]]
  then
    rsync -av --delete "${destination_directory}/geomaxima/features/" "${destination_directory}/web_app/geomaxima/features/"
    rsync -av --delete "${destination_directory}/geomaxima/templates/" "${destination_directory}/web_app/templates/"
    chown -R ${standard_user}:${standard_user} "${destination_directory}/web_app/geomaxima"
    chown -R ${standard_user}:${standard_user} "${destination_directory}/web_app/templates/geomaxima"
    echo 'GeoMaxima deployed successfully'
  else
    echo 'Warning: geomaxima directory not found, skipping GeoMaxima deployment'
  fi
  
  # restart str2str if it was active before upgrading rtklib
  [ $str2str_active = 'active' ] && systemctl restart str2str_tcp 
  [ $str2str_file = 'active' ] && systemctl restart str2str_file 
  [ $rtkrcv_raw2nmea = 'active' ] && systemctl restart rtkbase_raw2nmea
  # some users informed me that the archive time was not enabled, fix that:
  ! systemctl is-active --quiet rtkbase_archive.timer && systemctl enable --now rtkbase_archive.timer
  # restarting the gnss proxy service:
  systemctl is-active --quiet rtkbase_gnss_web_proxy.service && systemctl restart rtkbase_gnss_web_proxy.service 
  echo 'Main service restarted'
}

#check if we can apply the update
#FOR THE OLDER ME -> Don't forget to modify the os detection if there is a 2.7.x release !!!
[[ $checking == '--checking' ]] && check_before_update && exit

echo '################################'
echo 'Starting standard update'
echo '################################'
update || { echo 'Update failed (update)' ; exit 1 ;} 
# calling specific update function. If we are using v2.2.5, it will call the function upd_2.2.5
echo 'Starting specific update'
upd_"${old_version/b*/b}" "$@"  || { echo 'Update failed (upd_release_number)' ; exit 1 ;} 
#note for older me:
#When dealing with beta version, "${oldversion/b*/b}" will call function 2.4b when we use a release 2.4b1 or 2.4b2 or 2.4beta99

# The new version numbers will be imported from settings.conf.default during the web server startup.
echo "update the line version= and delete checkpoint_version= in settings.conf"
sed -i '/^checkpoint_version=/d' ${destination_directory}/settings.conf
new_version=$(grep '^version' ${destination_directory}/settings.conf.default | awk -F '=' '{ print $2 }')
sed -i 's/^version=.*/version='$new_version'/' ${destination_directory}/settings.conf
echo 'Insert updated status in settings.conf'
sed -i '/^\[general\]/a updated=true' ${destination_directory}/settings.conf

#change rtkbase's content owner
chown -R ${standard_user}:${standard_user} ${destination_directory}

#GeoMaxima - 2026-10-05 archive incident fix: ensure persistent journald
#retention on EVERY OTA, regardless of which version a station is
#updating from - unlike install_unit_files() in tools/install.sh (only
#called from version-gated upd_X.Y.Z() functions, so a station already
#past those version bumps would never receive it again), this runs
#unconditionally in the update tail every single time. Idempotent -
#install.sh's install_journald_retention() just rewrites the same
#drop-in and restarts journald, safe to repeat.
"${destination_directory}"/tools/install.sh --journald-retention --user "${standard_user}"

#GeoMaxima - 2026-10-05/06 incident investigation: fix audit.log's
#ownership on EVERY OTA, same unconditional pattern as journald
#retention above - a station already past whichever version-gated
#upd_X.Y.Z() function would otherwise ship this fix must still receive
#it, since archive_and_clean.sh's audit-log write depends on it on every
#single run, not just at upgrade time.
#
#GeoMaxima - 2026-10-13 review fix: --user was missing on BOTH calls above
#- _check_user() in tools/install.sh used to fall back to `logname`, which
#has no answer at all in a non-interactive context (confirmed live: an
#OTA running inside a systemd transient unit has no login session). Pass
#it explicitly everywhere install.sh is invoked from an OTA path, same as
#every other install.sh call in this file already does.
"${destination_directory}"/tools/install.sh --audit-log-access --user "${standard_user}"

  #restart str2str if it was active before upgrading rtklib
  # restart not nedeed if RTKlib was not upgraded
  #[ $str2str_active = 'active' ] && systemctl restart str2str_tcp
  #[ $rtkrcv_raw2nmea = 'active' ] && systemctl restart rtkbase_raw2nmea
  # str2str_file's own restart line used to be commented out here too -
  # GeoMaxima - 2026-10-05 archive incident fix: a station's File
  # service was left stopped for 4+ days after an OTA specifically
  # because of that. REMOVED here (no longer a hand-maintained,
  # easy-to-silently-disable single line) - superseded by the generic
  # _geomaxima_restore_service_states() call below, which restores EVERY
  # str2str_*/rtkbase_*/geomaxima_* service's pre-update active/inactive
  # state exactly (not just the hand-picked list below), and logs the
  # full before/after snapshot to audit.log.

  # restart previously running services
  # restart needed with all update to propagate the release number in the rtcm stream
  [ $str2str_ntrip_A_active = 'active' ] && systemctl restart str2str_ntrip_A
  [ $str2str_ntrip_B_active = 'active' ] && systemctl restart str2str_ntrip_B
  [ $str2str_local_caster = 'active' ] && systemctl restart str2str_local_ntrip_caster
  [ $str2str_rtcm = 'active' ] && systemctl restart str2str_rtcm_svr
  [ $str2str_serial = 'active' ] && systemctl restart str2str_rtcm_serial

#if a reboot is needed
#systemctl reboot

# GeoMaxima - 2026-10-05/06 incident investigation: restore every
# str2str_*/rtkbase_*/geomaxima_* service to its EXACT pre-update active
# state BEFORE restarting rtkbase_web.service, not after. The web
# restart is now the ABSOLUTE LAST command this script runs - this
# script is launched via `systemd-run --collect` (see
# web_app/server.py's update_rtkbase() and
# addons/features/ota_update/update_controller.py's perform_update()),
# outside rtkbase_web.service's own systemd cgroup, so that restart can
# no longer kill this script or anything after it - but the restore
# still belongs before the restart on its own merits, independent of
# that protection: a service "restored" after the very system it's
# meant to interoperate with (the just-restarted web app) has already
# come back up is restoring into a moving target, not a settled state.
_geomaxima_restore_service_states
rm -f "${GEOMAXIMA_SERVICE_STATE_FILE}" 2>/dev/null

echo 'RTKBase update ending...'
echo 'Restart web server'
systemctl restart rtkbase_web.service
