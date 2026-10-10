"""
GNSS Monitor - Monitor GNSS receiver connectivity
"""

import logging
import subprocess
import serial
import time
from typing import Dict, Optional
from pathlib import Path

logger = logging.getLogger(__name__)

# Extensions written DIRECTLY by str2str_file (raw receiver formats
# only). Deliberately EXCLUDES *.zip and *.tag:
#   - *.zip (archive_and_clean.sh's rotated/compressed archives): the
#     04:00 archive timer creates a NEW zip out of whatever raw file is
#     sitting in datadir, even if str2str_file stopped writing to it
#     hours or days ago - that zip's mtime is "now", not the age of the
#     data inside it. Including .zip here would make genuinely-stale
#     data look fresh for up to 24h after logging actually stopped,
#     directly defeating the point of this check.
#   - *.ubx.tag (and other sidecar/index files some receiver formats
#     write alongside the main file): not raw observation data itself.
_RAW_DATA_SUFFIXES = (
    '.ubx', '.rtcm', '.rtcm3', '.nov', '.oem', '.ss2', '.hemis', '.stq',
    '.javad', '.nvs', '.binex', '.sbf',
)

# str2str_file writes/appends to its CURRENT output file continuously
# while running (it does not buffer and flush only at rotation) - so
# while the service is active and healthy, the newest raw file's mtime
# is normally seconds to a few minutes old, never hours. Rotation
# (file_rotate_time, typically every 24h) starts a NEW file but does not
# change how often the ACTIVE file's mtime updates - there is always
# exactly one file receiving continuous writes at any given moment, so
# thresholds here can be tight (minutes), unlike a once-a-day archive
# check. WARNING at 30 minutes catches a stall early; CRITICAL at 2
# hours is the point a receiver hiccup has clearly become a sustained
# outage, not a transient reconnect.
RAW_DATA_WARNING_MINUTES = 30
RAW_DATA_CRITICAL_MINUTES = 120


class GNSSMonitor:
    """Monitor GNSS receiver data stream"""

    def __init__(self, config: Dict):
        """
        Initialize GNSS monitor

        Args:
            config: GNSS monitor configuration
        """
        self.config = config

    def check(self) -> Dict:
        """
        Check GNSS receiver connectivity

        Returns:
            Dict with GNSS status and incidents
        """
        results = {
            'status': 'ok',
            'receiver': {},
            'incidents': []
        }

        if not self.config.get('check_data_stream', True):
            results['receiver']['checked'] = False
            return results

        # Check serial port connectivity
        serial_port = self.config.get('serial_port', '/dev/ttyACM0')
        port_exists = Path(serial_port).exists()

        results['receiver']['serial_port'] = serial_port
        results['receiver']['port_exists'] = port_exists

        if not port_exists:
            results['status'] = 'critical'
            results['incidents'].append({
                'type': 'gnss_disconnected',
                'severity': 'critical',
                'message': f'GNSS receiver not found at {serial_port}'
            })
            return results

        # Try to read data from receiver
        data_ok = self._check_data_stream(serial_port)
        results['receiver']['data_streaming'] = data_ok

        if not data_ok:
            results['status'] = 'warning'

            if self.config.get('alert_on_failure', True):
                results['incidents'].append({
                    'type': 'gnss_no_data',
                    'severity': 'warning',
                    'message': f'GNSS receiver at {serial_port} is not streaming data'
                })

        if self.config.get('check_raw_data_freshness', True):
            self._check_raw_data_freshness(results)

        return results

    def _resolve_data_dir(self) -> Optional[Path]:
        """
        Resolve the raw-data directory - an explicit config override, or
        auto-detected from settings.conf's [local_storage] datadir via
        addons/settings_paths.py's resolve_datadir() (not a re-guessed
        path chain - that module implements the same $BASEDIR-expansion
        algorithm web_app/RTKBaseConfigManager.py's own expand_path()
        uses, verified to produce identical output for the real
        settings.conf.default format). Returns None if it can't be
        determined - caller must surface that as a
        visible warning incident (a misresolved path is itself exactly
        the kind of silent failure this check exists to catch), never
        silently skip without a trace.
        """
        configured = self.config.get('data_dir', '')
        if configured:
            return Path(configured)

        from addons.settings_paths import resolve_datadir

        for settings_path in (
            Path(__file__).resolve().parent.parent.parent.parent.parent / "settings.conf",
            Path("/etc/rtkbase/settings.conf"),
        ):
            resolved = resolve_datadir(settings_path)
            if resolved is not None:
                return resolved
        return None

    def _file_logging_active(self) -> Optional[bool]:
        """
        Whether str2str_file.service is currently active. None if the
        check itself couldn't run (systemctl missing/failed) - treated
        as "unknown", never assumed either way.
        """
        try:
            result = subprocess.run(
                ['systemctl', 'is-active', 'str2str_file.service'],
                capture_output=True, text=True, timeout=10,
            )
            return result.returncode == 0
        except (subprocess.SubprocessError, OSError, FileNotFoundError) as e:
            logger.warning(f"_file_logging_active: systemctl check failed: {e}")
            return None

    def _check_raw_data_freshness(self, results: Dict) -> None:
        """
        GeoMaxima - 2026-10-05 archive incident: raw GNSS data silently
        stopped flowing for 4+ days (File service stopped by an
        unrelated bug during an OTA - see rtkbase_update.sh's own
        incident comment) with nothing anywhere alerting on it, because
        every existing check (this monitor's own serial-port read above,
        the Autosurvey page, the archive timer) only looks at whether
        the RECEIVER is reachable/streaming, never at whether anything
        is actually landing in data_dir. This closes that gap directly:
        find the newest RAW (not archived) file's mtime and alert if
        it's older than the warning/critical thresholds.

        SURVEY INTERACTION: Autosurvey's one-owner rule
        (survey_controller.py's _ensure_file_logging()/
        _stop_file_logging()) legitimately starts and stops this SAME
        str2str_file.service - it never writes raw data anywhere else.
        So "str2str_file is not active" is NOT itself a failure; it's
        either the user's own choice or a survey intentionally not
        running continuous logging. Checking is-active FIRST and
        reporting that state explicitly (rather than only measuring raw
        file age) avoids a false CRITICAL whenever logging is
        legitimately stopped, while still raising a real alert if the
        service IS active but nothing is actually being written (the
        exact, confirmed failure mode of the incident - the service can
        show as active while wedged, if the underlying issue is the
        serial port/receiver rather than the service itself).

        Best-effort and non-fatal - any failure here is logged as a
        warning on the results dict, never raised, since a monitoring
        check must never itself take down the watchdog.
        """
        data_dir = self._resolve_data_dir()

        if data_dir is None:
            # A misresolved/unresolvable data_dir is itself a visible
            # problem (e.g. settings.conf missing/unreadable, or an
            # unexpected datadir value) - surfaced as a WARNING incident,
            # not a silent skip, per the same "never fail silently"
            # principle the rest of this incident's fixes apply.
            results['receiver']['raw_data_check'] = 'data_dir could not be resolved'
            results['status'] = 'warning' if results['status'] == 'ok' else results['status']
            results['incidents'].append({
                'type': 'raw_data_dir_unresolved',
                'severity': 'warning',
                'message': ('Could not resolve the raw-data directory from settings.conf - '
                           'raw-data-freshness checking is disabled until this is fixed')
            })
            return

        if not data_dir.is_dir():
            results['receiver']['raw_data_check'] = f'data_dir {data_dir} does not exist'
            results['status'] = 'warning' if results['status'] == 'ok' else results['status']
            results['incidents'].append({
                'type': 'raw_data_dir_unresolved',
                'severity': 'warning',
                'message': f'Resolved raw-data directory {data_dir} does not exist on disk'
            })
            return

        file_logging_active = self._file_logging_active()

        newest_mtime = None
        newest_name = None
        try:
            for entry in data_dir.iterdir():
                if not entry.is_file():
                    continue
                if entry.suffix.lower() not in _RAW_DATA_SUFFIXES:
                    continue
                mtime = entry.stat().st_mtime
                if newest_mtime is None or mtime > newest_mtime:
                    newest_mtime = mtime
                    newest_name = entry.name
        except OSError as e:
            logger.warning(f"_check_raw_data_freshness: failed to scan {data_dir}: {e}")
            results['receiver']['raw_data_check'] = f'scan failed: {e}'
            return

        if newest_mtime is None:
            if file_logging_active is False:
                # Expected: logging isn't running (user's choice, or no
                # survey needs it right now) and there's genuinely no raw
                # data yet/at all - not an incident.
                results['receiver']['raw_data_check'] = (
                    f'no raw data files in {data_dir} - str2str_file.service is not '
                    f'active (expected if logging has never been enabled, or is not '
                    f'currently owned by a survey)'
                )
                return
            results['receiver']['raw_data_check'] = f'no raw data files found in {data_dir} at all'
            results['status'] = 'critical'
            results['incidents'].append({
                'type': 'raw_data_missing',
                'severity': 'critical',
                'message': (f'No raw GNSS data files found in {data_dir} at all, and '
                           f'str2str_file.service is active or its state could not be '
                           f'determined - data should be present')
            })
            return

        age_minutes = (time.time() - newest_mtime) / 60.0
        results['receiver']['raw_data_newest_file'] = newest_name
        results['receiver']['raw_data_age_minutes'] = round(age_minutes, 1)
        results['receiver']['str2str_file_active'] = file_logging_active

        if file_logging_active is False:
            # Logging is intentionally stopped - staleness is expected,
            # not an incident. Reported clearly on the results dict (for
            # the UI) rather than hidden, so "raw logging is currently
            # owned by the user/not running, last data is Xmin old" is
            # always visible without being raised as a false alarm.
            results['receiver']['raw_data_check'] = (
                f'raw logging not active (str2str_file.service inactive) - '
                f'last data {age_minutes:.1f}min old, not an incident'
            )
            return

        if age_minutes > RAW_DATA_CRITICAL_MINUTES:
            results['status'] = 'critical'
            results['incidents'].append({
                'type': 'raw_data_stale',
                'severity': 'critical',
                'message': (f'str2str_file.service is active but the newest raw GNSS data '
                           f'file ({newest_name}) in {data_dir} is {age_minutes:.0f}min old '
                           f'(threshold {RAW_DATA_CRITICAL_MINUTES}min) - logging appears '
                           f'wedged (e.g. receiver/serial port issue)')
            })
        elif age_minutes > RAW_DATA_WARNING_MINUTES:
            results['status'] = 'warning' if results['status'] == 'ok' else results['status']
            results['incidents'].append({
                'type': 'raw_data_stale',
                'severity': 'warning',
                'message': (f'str2str_file.service is active but the newest raw GNSS data '
                           f'file ({newest_name}) in {data_dir} is {age_minutes:.0f}min old '
                           f'(threshold {RAW_DATA_WARNING_MINUTES}min)')
            })

    def _check_data_stream(self, serial_port: str) -> bool:
        """
        Check if data is coming from receiver

        Args:
            serial_port: Serial port path

        Returns:
            True if data is streaming
        """
        timeout = self.config.get('timeout_seconds', 10)

        try:
            # Try to open serial port and read some data
            with serial.Serial(serial_port, baudrate=115200, timeout=timeout) as ser:
                # Read a few lines to ensure data is flowing
                for _ in range(5):
                    line = ser.readline()
                    if line:
                        # Got data - receiver is streaming
                        return True

                # No data received
                return False

        except serial.SerialException as e:
            logger.error(f"Serial port error: {e}")
            return False
        except Exception as e:
            logger.error(f"Failed to check GNSS data stream: {e}")
            return False
