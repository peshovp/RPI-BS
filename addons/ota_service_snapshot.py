"""
Pre-OTA service-state snapshot - written BEFORE any shutdown/stop step,
read by the update script (addons/tools/rtkbase_update.sh /
addons/tools/perform_update.sh) once it has finished, so a service's
active/enabled state can be restored to what it genuinely was before the
update process (including the web app's own pre-update shutdown calls)
touched anything - not just what rtkbase_update.sh's own shell-side
snapshot (taken AFTER the Flask app's shutdown step has already run)
would see.

GeoMaxima - 2026-10-05/06 incident investigation: confirmed that
rtk.shutdownBase() (RTKLIB.py's shutdownBase()) does NOT touch any
systemd service - it only manages the in-process rtkrcv TCP client and
Python threads, so it never directly stops str2str_file or any other
unit. This module's snapshot is still taken before any OTA step runs, as
defense in depth and to make the actual pre-update state independently
verifiable/reconstructable, regardless of what any later investigation
finds actually caused a particular service's state to change.

REVIEW FIXES (2026-10-07):
- Covers BOTH .service AND .timer units now - rtkbase_archive.timer
  itself is exactly the kind of unit an OTA's own unit-file redeploy
  (copy_unit.sh) could re-enable/disable as a side effect, and the
  prior version only looked at .service units.
- Stores the RAW systemctl state strings (active/inactive/activating/
  deactivating/failed; enabled/disabled/static/masked/indirect/alias/
  generated/transient), not booleans. A boolean collapsed e.g.
  "static" and "enabled" into the same True, or "failed" and "active"
  into the same False - both wrong restoration targets. The restore
  side (addons/tools/rtkbase_update.sh) only ever flips active<->
  inactive and enabled<->disabled - static/masked/indirect/alias/
  generated/transient units are left exactly as found, never unmasked
  or force-enabled.
- Carries a run_id (passed in by the caller, matched against by the
  update script) and a timestamp, so a STALE snapshot from a previous,
  unrelated run can never be mistaken for this run's own pre-update
  state - the update script only trusts a snapshot that is both
  younger than SNAPSHOT_MAX_AGE_SECONDS and whose run_id matches what
  it was given.
"""

import json
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

SNAPSHOT_PATH = Path("/var/lib/rtkbase/ota/service_state_before.json")

# How long a snapshot is trusted as "fresh enough to be THIS run's
# pre-update state" - generous enough to cover update-check + download +
# launch latency, short enough that a stale leftover from a failed or
# long-ago run is never silently reused.
SNAPSHOT_MAX_AGE_SECONDS = 1800

# Same unit-name pattern addons/tools/rtkbase_update.sh's own
# _geomaxima_service_units() uses - str2str_*/rtkbase_*/geomaxima_*
# units, discovered dynamically (not a hand-maintained list). Both
# .service and .timer, per the review fix above.
_UNIT_PREFIXES = ("str2str_", "rtkbase_", "geomaxima_")
_UNIT_SUFFIXES = (".service", ".timer")


def _list_units() -> list:
    try:
        result = subprocess.run(
            ['systemctl', 'list-unit-files', '--no-legend'],
            capture_output=True, text=True, timeout=15,
        )
    except (subprocess.SubprocessError, OSError):
        return []
    units = []
    for line in result.stdout.splitlines():
        parts = line.split()
        if not parts:
            continue
        name = parts[0]
        if not name.endswith(_UNIT_SUFFIXES):
            continue
        if '@' in name:
            continue
        if name.startswith(_UNIT_PREFIXES):
            units.append(name)
    return sorted(set(units))


def _systemctl_state(subcommand: str, unit: str) -> str:
    """Raw systemctl is-active/is-enabled output (stdout, stripped) -
    e.g. 'active', 'inactive', 'failed', 'enabled', 'disabled',
    'static', 'masked', 'indirect'. Never raises; returns 'unknown' on
    any failure to run the check itself (NOT the same as a legitimate
    systemctl answer like 'inactive' - callers must not treat 'unknown'
    as either active or inactive)."""
    try:
        result = subprocess.run(
            ['systemctl', subcommand, unit],
            capture_output=True, text=True, timeout=10,
        )
        state = (result.stdout or '').strip()
        return state if state else 'unknown'
    except (subprocess.SubprocessError, OSError):
        return 'unknown'


def write_snapshot(run_id: str) -> bool:
    """
    Capture the raw is-active/is-enabled state for every str2str_*/
    rtkbase_*/geomaxima_* service AND timer unit, and write it to
    SNAPSHOT_PATH (root 0600) tagged with `run_id` and the current UTC
    timestamp. Best-effort: returns False (logged, never raises) on any
    failure - a snapshot failure must never block whatever OTA step is
    about to run; callers must wrap this in their own try/except too
    (defense in depth - see both web_app/server.py's update_rtkbase()
    and addons/features/ota_update/update_controller.py's
    perform_update(), which both do).

    :param run_id: an identifier unique to THIS OTA invocation (e.g. a
        timestamp or uuid) - the SAME value must be passed to whatever
        reads this snapshot back, so a stale snapshot from an unrelated
        or previous run is never mistaken for this run's pre-update
        state (see read_snapshot()'s own run_id matching).
    :return: True if the snapshot was written successfully
    """
    try:
        units = {}
        for unit in _list_units():
            units[unit] = {
                'active': _systemctl_state('is-active', unit),
                'enabled': _systemctl_state('is-enabled', unit),
            }

        SNAPSHOT_PATH.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            'run_id': run_id,
            'timestamp': datetime.now(timezone.utc).isoformat(),
            'units': units,
        }
        tmp_path = SNAPSHOT_PATH.with_suffix('.tmp')
        with open(tmp_path, 'w') as f:
            json.dump(payload, f, indent=2)
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, SNAPSHOT_PATH)
        return True
    except (OSError, subprocess.SubprocessError) as e:
        print(f"ota_service_snapshot.write_snapshot: failed (OTA proceeds anyway): {e}")
        return False


def read_snapshot(run_id: str) -> Optional[dict]:
    """
    Read back a snapshot written by write_snapshot(), but ONLY if its
    run_id matches `run_id` and it is younger than
    SNAPSHOT_MAX_AGE_SECONDS - otherwise returns None (caller must fall
    back to its own, later snapshot in that case, and should log that
    the fallback may already be post-shutdown).

    Deletes the snapshot file after a successful, matching read (one-
    shot - a stale file left behind must never be reused by a LATER,
    unrelated run).

    :return: {'timestamp': str, 'units': {unit: {'active': str,
        'enabled': str}}}, or None if no usable snapshot exists
    """
    try:
        if not SNAPSHOT_PATH.exists():
            return None
        with open(SNAPSHOT_PATH) as f:
            data = json.load(f)
        if data.get('run_id') != run_id:
            return None
        written_at = datetime.fromisoformat(data['timestamp'])
        age_seconds = (datetime.now(timezone.utc) - written_at).total_seconds()
        if age_seconds > SNAPSHOT_MAX_AGE_SECONDS or age_seconds < 0:
            return None
        try:
            SNAPSHOT_PATH.unlink()
        except OSError:
            pass
        return data
    except (OSError, ValueError, KeyError, json.JSONDecodeError):
        return None
