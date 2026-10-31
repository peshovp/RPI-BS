"""
Auto Survey-In Controller
=========================

Main controller for 24-hour automatic survey-in process.

Orchestrates:
- RTKBase configuration auto-discovery
- GNSS data logging (enables str2str_file if needed)
- RINEX conversion from raw logs
- PRIDE-PPPAR (pdp3) ambiguity-resolved PPP-static positioning
- Geoid correction
- ITRF2020 -> BGS2005 transformation (Инструкция № РД-02-20-25, Чл.22,
  ал.1 - see bgs2005_transformer.py) before RTCM broadcast
- RTKBase configuration updates
- State persistence

PRIDE-PPPAR is the only positioning backend - no SPP or rnx2rtkp fallback.
A failed product wait or PPP run surfaces as a recorded failure and is
retried by the final loop; it never silently degrades.
"""

import logging
import math
import re
import shutil
import time
import subprocess
from pathlib import Path
from typing import Optional, Dict, Tuple
from datetime import datetime, timedelta
import threading
import os
import requests

from .rtkbase_config import RTKBaseConfig
from .runtime_paths import GM_RUNTIME_DIR
from .rinex_converter import RINEXConverter
from .antex_support import AntexSupport, antenna_type_in_antex, classify_band_calibration
from .pride_pppar_processor import (
    PridePpparProcessor, Pdp3NotFoundError, check_processed_window_coverage,
    PPP_AR_SAMPLE_INTERVAL_S,
)
from .ppp_ar_failure import describe_failure, STAGE_PDP3_FAILED, STAGE_FIX_RATE_BELOW_THRESHOLD, STAGE_APPLY_FAILED
from .product_availability import check_products_available
from .bgs2005_transformer import GeodeticPoint, itrf2020_to_bgs2005, extract_observation_epoch, extract_observation_duration_minutes, verify_rtcm_broadcast_ecef, arp_to_marker, verify_arp_to_marker_offset
from .geoid_corrector import GeoidCorrector
from .state_manager import StateManager, SurveyState

try:
    from audit_logger import log_event  # web process: web_app/ is on sys.path
except ImportError:
    try:
        # survey runner service (python -m ...): the repository root is the
        # working directory, web_app/ is importable as a namespace package.
        # Without this fallback every audit event of the survey (start, stop,
        # reset, failed, recovered) would be silently dropped in the runner.
        from web_app.audit_logger import log_event
    except ImportError:
        log_event = lambda *a, **k: None

logger = logging.getLogger(__name__)

# Caster endpoint that pre-tags an upcoming service restart's resulting
# disconnect as planned (e.g. an auto-survey coordinate update), instead
# of the caster logging it as an unexplained failure. Confirmed live via
# curl against BaseStation (2026-08-14): HTTP/2 200,
# {"success": true, "ttl_seconds": 120.0}. The {mount} path segment is
# filled in per-call from this station's own mnt_name_a - not hardcoded.
_CASTER_ANNOUNCE_URL_TEMPLATE = "https://caster.geomaxima.bg/api/v1/bases/{mount}/announce-planned-disconnect"


def _get_announce_credentials(rtkbase: RTKBaseConfig) -> Tuple[Optional[str], Optional[str]]:
    """
    Read this station's NTRIP A mount name and caster announce token from
    settings.conf, using the exact same access pattern already used
    elsewhere in this file (self.rtkbase.config.get(section, key,
    fallback=...).strip("'") - see recover_survey()'s receiver_format
    read) rather than ConfigManager (only used here for antenna
    position) or a new parser instance.

    NOTE: rtkbase.config is loaded once at RTKBaseConfig.__init__ and
    never re-read from disk afterwards (confirmed - no reload/read()
    call anywhere else in that class). If the operator saves a new
    announce token via the Settings UI while a survey is already
    running, this survey process will keep using whatever value (or
    absence of one) it read at recover_survey()/__init__ time until the
    next restart - not a live-reloaded setting.

    :param rtkbase: this controller's RTKBaseConfig instance
    :return: (mount_name, announce_token) - either may be None/empty if
        not configured; callers must treat that as "skip silently", not
        as an error.
    """
    mount_name = rtkbase.config.get('ntrip_A', 'mnt_name_a', fallback='').strip("'")
    announce_token = rtkbase.config.get('ntrip_A', 'caster_announce_token', fallback='').strip("'")
    return (mount_name or None, announce_token or None)


def _announce_planned_disconnect(rtkbase: RTKBaseConfig, reason: str = "auto_survey") -> None:
    """
    Tell the caster an upcoming service restart is expected (e.g. to
    apply refined auto-survey coordinates), so it doesn't log the
    resulting disconnect as an unexplained failure. Uses the dedicated,
    lower-privilege announce token configured in NTRIP Service settings
    (caster_announce_token) - NEVER svr_pwd_a, this station's actual
    NTRIP login password.

    Best-effort only: must never block, delay, or fail the actual
    coordinate update/restart that's about to happen. The 5s timeout and
    the try/except below mean a slow/unreachable/erroring caster costs
    at most ~5s here and then falls through to the restart exactly as if
    this function had not been called at all.

    :param rtkbase: this controller's RTKBaseConfig instance
    :param reason: short machine-readable reason tag sent to the caster
    """
    try:
        mount_name, announce_token = _get_announce_credentials(rtkbase)
        if not mount_name or not announce_token:
            logger.debug(
                "Caster announce token not configured - skipping "
                "planned-disconnect announcement (restarts still work "
                "normally, just won't be pre-tagged). Configure it in "
                "NTRIP Service settings if you want this."
            )
            return

        url = _CASTER_ANNOUNCE_URL_TEMPLATE.format(mount=mount_name)
        resp = requests.post(
            url,
            json={"token": announce_token, "reason": reason},
            timeout=5,
        )
        if resp.status_code == 200:
            logger.debug(f"Caster planned-disconnect announcement accepted for mount={mount_name!r}: {resp.text}")
        else:
            # Non-fatal: e.g. 401 for a stale/revoked token. Restarts
            # still proceed normally; this is audit-log quality only.
            logger.warning(
                f"Caster planned-disconnect announcement rejected "
                f"(HTTP {resp.status_code}) for mount={mount_name!r}: {resp.text[:200]}"
            )
    except Exception as e:
        logger.warning(f"Failed to announce planned disconnect to caster: {e}")

class SurveyController:
    """
    Auto Survey-In orchestration with RTKBase integration
    
    Features:
    - Auto-discovers RTKBase configuration
    - Enables file logging automatically
    - Converts raw logs to RINEX
    - Processes with PRIDE-PPPAR (pdp3) PPP-AR static positioning
    - Transforms ITRF2020 -> BGS2005 before broadcast (Инструкция №
      РД-02-20-25, Чл.22, ал.1)
    - Updates RTKBase config hourly
    """

    def _migrate_runtime_dir_from_repo_root(self, old_name: str, new_name: str) -> Path:
        """
        One-time move of a runtime data directory from its old location
        directly under the git checkout (self.rtkbase.rtkbase_root /
        old_name) to its new home under GM_RUNTIME_DIR / new_name.

        Idempotent: if the old directory doesn't exist, or the new one
        already exists, nothing is moved. A destination that already has
        content is never merged into or overwritten - the old directory is
        left in place (logged) so nothing already-migrated could be lost.

        Returns the directory the CALLER should actually use: the new
        location once migrated (or if there was nothing to migrate), or
        the old in-repo location if the move itself failed (e.g. a
        cross-filesystem move, a permissions issue) - never silently
        switches to a fresh, empty new_dir while real data sits orphaned
        in the old one. A failed migration is retried on the next start.
        """
        old_dir = self.rtkbase.rtkbase_root / old_name
        new_dir = GM_RUNTIME_DIR / new_name
        if not old_dir.exists():
            return new_dir
        if new_dir.exists():
            if any(new_dir.iterdir()):
                logger.warning(f"Both {old_dir} (old) and {new_dir} (new, non-empty) exist - "
                               f"leaving {old_dir} in place; merge it into {new_dir} manually if needed.")
            return new_dir
        try:
            GM_RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
            shutil.move(str(old_dir), str(new_dir))
            logger.info(f"Migrated runtime data: {old_dir} -> {new_dir} (no longer inside the git checkout)")
            return new_dir
        except OSError as e:
            logger.warning(f"Could not migrate {old_dir} to {new_dir}: {e} - using {old_dir} for this run, will retry on next start")
            return old_dir

    def __init__(self,
                 settings_file: str = None,
                 state_file: str = "/var/lib/rtkbase/survey_state.json",
                 auto_mode: bool = True):
        """
        Args:
            settings_file: Path to RTKBase settings.conf
            state_file: Path to survey state persistence file
            auto_mode: Enable automatic RTKBase integration
        """
        self.auto_mode = auto_mode

        if settings_file is None:
            # Resolve rtkbase root the same way web_app/server.py does: relative
            # to this file's location, not $HOME (this may run as root via systemd).
            _rtkbase_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../"))
            settings_file = os.path.join(_rtkbase_root, "settings.conf")

        # Initialize RTKBase config parser
        try:
            self.rtkbase = RTKBaseConfig(settings_file)
        except Exception as e:
            logger.error(f"Failed to load RTKBase config: {e}")
            raise
        
        # Initialize components
        self.rinex = RINEXConverter()
        self.antex = AntexSupport(rtkbase_root=self.rtkbase.rtkbase_root)
        self.geoid = GeoidCorrector()
        self.state = StateManager(state_file)

        # Geoid config (upload directory + persisted config). GeoMaxima:
        # moved OUT of the git checkout to GM_RUNTIME_DIR (/var/lib/rtkbase
        # by default) - confirmed live, this was being created directly
        # under rtkbase_root (the repo root), showing up as untracked
        # clutter in `git status` on every station. See runtime_paths.py's
        # module docstring. Existing data from the old in-repo location is
        # moved on first start so no station loses its uploaded geoid model.
        self.geoid_dir = self._migrate_runtime_dir_from_repo_root("geomaxima_geoid", "geoid")
        self.geoid_dir.mkdir(parents=True, exist_ok=True)
        self.geoid_config_path = self.geoid_dir / "geoid_config.json"
        self._load_geoid_model()
        
        # Survey parameters
        self.target_hours = 24
        # Last "PPP-AR ATTEMPT ..." summary line logged by
        # _log_ppp_ar_attempt() - used by
        # _finalize_survey()'s "No final position computed" error path to
        # surface the actual last PPP-AR failure reason instead of a
        # generic, context-free message. None until the first PPP-AR
        # attempt of this instance's lifetime.
        self._last_ppp_ar_attempt_summary = None

        # True only in the survey runner service (geomaxima_survey.service,
        # see survey_runner.py), the single owner of the survey thread and of
        # every state change. The web application also builds a controller,
        # but only to READ the state (reloaded from disk on every
        # get_status()) and for the geoid helpers; it never auto-applies a
        # position, never resumes and never starts a survey itself.
        self.is_runner = False
        # Runner only: a survey is persisted as 'running' but could not be
        # resumed yet (e.g. the receiver stream is not up after a reboot).
        # The runner retries recover_survey() while this is True instead of
        # failing a healthy survey.
        self.recovery_pending = False

        # Working directory for temp files. GeoMaxima: moved OUT of the git
        # checkout to GM_RUNTIME_DIR - same reasoning/migration as geoid_dir
        # above.
        self.work_dir = self._migrate_runtime_dir_from_repo_root("geomaxima_survey", "survey")
        self.work_dir.mkdir(parents=True, exist_ok=True)
        
        # Control flags
        self._running = False
        self._thread: Optional[threading.Thread] = None
        self._services_restarted = False  # Track if services were restarted after completion
        
        logger.info(f"Survey controller initialized (auto_mode={auto_mode})")
        logger.info(f"Work dir: {self.work_dir}")
    
    def _ensure_file_logging(self) -> bool:
        """
        Make sure RTKBase file logging (str2str_file.service) runs for
        this survey.

        SURVEY-ONLY policy (Pesho's decision, 2026-10-14): the File service
        is OFF by default and runs only while an Autosurvey runs. The
        survey therefore ALWAYS owns it: it starts it at survey start (a
        plain `systemctl start`, which does not enable the unit) and
        _stop_file_logging() stops it when the survey ends for ANY reason.
        There is no "claim only if inactive" / "only if the user has not
        enabled it" heuristic any more - the earlier one-owner heuristic
        (2026-10-01) existed because a stale ownership latch stopped a
        service while no survey ran; the policy removes the ambiguity
        instead: ownership lasts exactly as long as the survey. The start
        time is recorded in the survey state (file_service_started_at).

        Returns:
            True if logging is active or successfully started
        """
        try:
            result = subprocess.run(
                ['systemctl', 'is-active', 'str2str_file.service'],
                capture_output=True,
                text=True
            )
            if result.returncode == 0:
                logger.info("✓ File logging service already running - owned by this survey "
                            "for its duration (survey-only policy)")
                self.state.set_file_service_owned(True)
                return True

            logger.info("Starting file logging service...")
            result = subprocess.run(
                ['systemctl', 'start', 'str2str_file.service'],
                capture_output=True,
                text=True
            )

            if result.returncode == 0:
                logger.info("✓ File logging service started (owned by this survey)")
                self.state.set_file_service_owned(True)
                return True
            else:
                logger.warning(f"Could not start file logging: {result.stderr}")
                return False

        except Exception as e:
            logger.error(f"Failed to enable file logging: {e}")
            return False


    # Raw log must have grown within this many seconds to count as "alive" -
    # str2str_file.service can stay systemd-active while the receiver has
    # stopped sending data entirely (cable unplugged, receiver power loss,
    # serial port wedged), which `systemctl is-active` alone cannot detect.
    FILE_LOGGING_STALE_SECONDS = 180
    # Right after the survey starts the File service, str2str needs a moment
    # to create the raw log; within this grace a missing raw file is "starting",
    # not a crash (observed live: a false "crashed during survey" record on
    # the very first health check).
    FILE_LOGGING_STARTUP_GRACE_SECONDS = 90

    # After this many consecutive restart attempts (success OR failure - a
    # receiver that keeps dropping and reconnecting is a real problem even
    # if each individual restart technically "succeeds"), stop backing off
    # silently and raise a clear, persistent incident instead.
    FILE_LOGGING_INCIDENT_THRESHOLD = 5

    # Cap on the exponential back-off between restart attempts. Raw GNSS
    # data IS the entire point of a running survey - once a receiver is
    # re-plugged/powered back on, waiting up to an hour for the next retry
    # (the original cap) would needlessly stall data collection; 10 minutes
    # still comfortably avoids a restart storm while staying short enough
    # that a human re-plugging a cable sees it recovered quickly.
    FILE_LOGGING_BACKOFF_CAP_SECONDS = 600

    def _file_service_just_started(self) -> bool:
        """True while the survey took ownership of the File service less than
        FILE_LOGGING_STARTUP_GRACE_SECONDS ago (state: file_service_started_at)."""
        try:
            started_at = self.state.get_status().get('file_service_started_at')
            if not started_at:
                return False
            age = (datetime.utcnow() - datetime.fromisoformat(started_at)).total_seconds()
            return 0 <= age < self.FILE_LOGGING_STARTUP_GRACE_SECONDS
        except Exception:
            return False

    def _is_file_logging_alive(self) -> Tuple[bool, str]:
        """
        True only if str2str_file.service is BOTH systemd-active AND its
        raw log file has grown within FILE_LOGGING_STALE_SECONDS. Returns
        (alive, detail) - detail explains which check failed, for logging/
        the UI, never raises (a failure to even check counts as not alive,
        so a transient inspection error doesn't mask a real outage).
        """
        try:
            result = subprocess.run(
                ['systemctl', 'is-active', 'str2str_file.service'],
                capture_output=True, text=True
            )
            if result.returncode != 0:
                return False, f"systemctl is-active: {result.stdout.strip() or 'inactive'}"
        except Exception as e:
            return False, f"systemctl is-active check failed: {e}"

        try:
            raw_file = self.rtkbase.get_data_file()
            if raw_file is None or not raw_file.exists():
                if self._file_service_just_started():
                    return True, "starting (raw log not created yet)"
                return False, "no raw log file found"
            age = time.time() - raw_file.stat().st_mtime
            if age > self.FILE_LOGGING_STALE_SECONDS:
                return False, (f"service active but raw log {raw_file.name} has not grown in "
                               f"{age:.0f}s (receiver may have stopped sending data)")
        except Exception as e:
            return False, f"raw log liveness check failed: {e}"

        return True, ""

    def _survey_loop(self):
        """
        Main survey loop - runs in the survey runner's background thread.

        Data collection runs until the target duration is reached; then
        _finalize_survey() takes over: it computes the final PRIDE-PPPAR
        position automatically once the precise products of the observation
        days are published (see product_availability.py). There are no
        interim positions: the products of an observation day appear ~13-19 h
        after the day ends, so an interim run on the day's own data cannot
        complete. The loop also keeps the File service healthy and the
        liveness heartbeat fresh.
        """
        # IMPORTANT: Use persisted state start_time so recovery/restarts don't reset elapsed time.
        status = self.state.get_status()
        start_time_raw = status.get('start_time')
        if start_time_raw:
            start_time = datetime.fromisoformat(start_time_raw)
        else:
            # Should not happen for RUNNING surveys, but keep loop resilient.
            start_time = datetime.utcnow()
            logger.warning("Survey state missing start_time; using current time")

        logger.info(f"Survey loop started, target: {self.target_hours} hours")
        last_file_logging_check = datetime.min

        try:
            while self._running:
                # Stop doing work if state is not RUNNING/FINALIZING (e.g., paused/reset from UI)
                if self.state.survey_state not in (SurveyState.RUNNING, SurveyState.FINALIZING):
                    time.sleep(2)
                    continue

                now = datetime.utcnow()
                elapsed_hours = (now - start_time).total_seconds() / 3600

                # str2str_file.service crash check (only acts while this survey
                # owns the service - see _check_file_logging_health()).
                if (now - last_file_logging_check).total_seconds() >= self.FILE_LOGGING_HEALTH_CHECK_INTERVAL_SECONDS:
                    self._check_file_logging_health()
                    last_file_logging_check = now

                # Liveness heartbeat for the status page / operator (written at
                # most once per HEARTBEAT_INTERVAL_SECONDS).
                self.state.record_heartbeat(self.HEARTBEAT_INTERVAL_SECONDS)

                # Check if survey completed (persisted start_time makes this reliable after restart)
                if elapsed_hours >= self.target_hours:
                    logger.info(f"Target duration reached ({self.target_hours}h), performing final update...")
                    self._finalize_survey()
                    break

                time.sleep(10)

        except Exception as e:
            logger.error(f"Survey loop error: {e}", exc_info=True)
            self._fail(str(e))
            self._running = False

    def _check_file_logging_health(self) -> None:
        """
        Periodic health check for str2str_file.service while this survey
        OWNS it (file_service_owned - see _ensure_file_logging()). Checks
        BOTH that the service is active AND that the raw log is actually
        growing (see _is_file_logging_alive()) - "active but not writing"
        (receiver stopped sending, service itself still up) is otherwise
        invisible to a plain `systemctl is-active` check.

        _ensure_file_logging() only ran once, at survey start - nothing
        re-checked the service for the rest of a 24h survey, so a crash
        mid-survey went unnoticed and the raw log simply stopped growing
        until the survey's own update-timeout eventually fired for an
        unrelated-looking reason. ONE owner rule: Watchdog explicitly
        never restarts a disabled service (see ServiceMonitor), and
        str2str_file.service is never in Watchdog's default monitored
        list - so when this survey owns the service, nothing else will
        ever restart it; this method is that owner's health check. When
        the survey does NOT own it (file_service_owned is False - either
        logging was already active before start_survey(), or this
        survey's own attempt to start it never succeeded), this method
        does nothing: whoever actually owns the service is responsible
        for it, not this survey.

        Restart storm protection: a hardware-level problem (receiver
        unplugged, serial device gone) would otherwise get a fresh
        `systemctl start` call every single check interval forever. Back
        off exponentially between attempts (base interval doubled per
        consecutive failure, capped), and once
        FILE_LOGGING_INCIDENT_THRESHOLD consecutive restarts have been
        needed, raise a persistent incident
        (state.record_file_logging_incident() - a dedicated field, kept
        separate from record_update_failure()'s own failure tracking, see
        the comment at that call below) while still continuing to retry at
        the capped backed-off interval rather than giving up entirely - a
        receiver that comes back after 20 minutes should still get picked
        back up automatically.

        The consecutive-failure counter is state (persisted to disk, see
        StateManager.record_file_logging_restart()), not an in-process
        variable, so back-off and the incident threshold both survive an
        app restart mid-survey (e.g. an OTA update restarting
        rtkbase_web.service) exactly like every other piece of survey
        progress already does.

        Never raises; failures here must not take down the survey loop.
        """
        if not self.state.get_file_service_owned():
            return

        try:
            alive, detail = self._is_file_logging_alive()
            if alive:
                self.state.record_file_logging_healthy()
                return

            failures_so_far = self.state.get_status().get('file_logging_consecutive_failures', 0)
            backoff_seconds = min(
                self.FILE_LOGGING_HEALTH_CHECK_INTERVAL_SECONDS * (2 ** failures_so_far),
                self.FILE_LOGGING_BACKOFF_CAP_SECONDS
            )
            last_restart = self.state.get_status().get('file_logging_last_restart')
            if last_restart:
                since_last = (datetime.utcnow() - datetime.fromisoformat(last_restart['timestamp'])).total_seconds()
                if since_last < backoff_seconds:
                    logger.debug(f"_check_file_logging_health: {detail} - backing off, "
                                f"next attempt in {backoff_seconds - since_last:.0f}s "
                                f"(consecutive failures: {failures_so_far})")
                    return

            logger.warning(f"str2str_file.service (owned by this survey) is not healthy: {detail} - "
                           f"attempting restart (consecutive failures so far: {failures_so_far})")
            restart = subprocess.run(
                ['systemctl', 'start', 'str2str_file.service'],
                capture_output=True, text=True
            )
            if restart.returncode == 0:
                self.state.record_file_logging_restart(success=True, detail=f"systemctl start succeeded ({detail})")
            else:
                self.state.record_file_logging_restart(
                    success=False, detail=restart.stderr.strip() or f"systemctl start failed ({detail})")

            new_failure_count = self.state.get_status().get('file_logging_consecutive_failures', 0)
            if new_failure_count >= self.FILE_LOGGING_INCIDENT_THRESHOLD:
                # Deliberately NOT record_update_failure(): that field feeds
                # the survey-wide hard-timeout's displayed failure reason
                # (last_failure_reason) and a SEPARATE, position-update
                # consecutive_failures counter - conflating a raw-logging
                # incident with those would both corrupt an unrelated
                # counter and show a misleading reason if the real timeout
                # ever fires for a different cause later. This incident
                # lives entirely in its own field
                # (file_logging_incident_active, surfaced on the Autosurvey
                # page same as file_logging_last_restart), and retries
                # continue at the capped backed-off interval regardless -
                # raising it is visibility, not a stop condition.
                self.state.record_file_logging_incident(
                    f"{new_failure_count} consecutive restart attempts needed. "
                    f"Check the receiver connection. Last: {detail}"
                )
        except Exception as e:
            logger.error(f"_check_file_logging_health: unexpected error: {e}", exc_info=True)

    def _stop_file_logging(self, reason: str = "unknown") -> bool:
        """
        Stop RTKBase file logging service when the survey ends.

        SURVEY-ONLY policy (Pesho's decision, 2026-10-14): the survey owns
        str2str_file.service for its whole duration and stops it when it
        ends for ANY reason (success, failure, cancel, runner death found
        on reconcile). No ownership-latch precondition and no is-enabled
        check: the stale-latch incident of 2026-10-01 (a stale True from a
        long-finished survey stopped a service the user relied on) is
        resolved by the policy itself - there is no legitimate File
        service use outside a survey. A plain `systemctl stop` (never
        disable - disabling is reserved for the UI toggle) is used, and the
        ownership flag is cleared on every path.

        Args:
            reason: Short label identifying which code path triggered the stop
                (e.g. "manual_stop", "survey_completed", "survey_failed"),
                logged for future diagnosis.

        Returns:
            True if logging is stopped (or already was).
        """
        logger.info(f"Stopping file logging (reason: {reason})")
        try:
            # Check if service is running first
            result = subprocess.run(
                ['systemctl', 'is-active', 'str2str_file.service'],
                capture_output=True,
                text=True
            )

            if result.returncode != 0:  # Service not active
                logger.info("File logging service already stopped")
                self.state.set_file_service_owned(False)
                return True

            # Stop the service
            logger.info("Stopping file logging service to prevent disk space issues...")
            result = subprocess.run(
                ['systemctl', 'stop', 'str2str_file.service'],
                capture_output=True,
                text=True
            )

            if result.returncode == 0:
                logger.info("✓ File logging service stopped")
                self.state.set_file_service_owned(False)
                return True
            else:
                logger.warning(f"Could not stop file logging: {result.stderr}")
                return False

        except Exception as e:
            logger.error(f"Failed to stop file logging: {e}")
            return False
    
    def start_survey(self, target_hours: int = 24, apply_mode: str = 'apply') -> bool:
        """
        Start new survey session

        Args:
            target_hours: Survey duration in hours (default: 24). When it is
                over, data collection stops and the final PRIDE-PPPAR position
                is computed automatically once the precise products are
                published (see _finalize_survey()).
            apply_mode: 'apply' (default) applies the final result to the
                broadcast position; 'propose' only stores it as a proposal
                (the broadcast position is never changed by the survey).

        Returns:
            True if started successfully
        """
        if self._running:
            logger.warning("Survey already running")
            return False

        # Ensure file logging is enabled
        if self.auto_mode:
            if not self._ensure_file_logging():
                logger.error("File logging could not be started")
                return False

        # Initialize state
        self.target_hours = target_hours
        if not self.state.start_survey(target_hours, apply_mode=apply_mode):
            logger.error("Failed to initialize survey state")
            return False
        
        # Start survey thread
        self._running = True
        self._thread = threading.Thread(target=self._survey_loop, daemon=True)
        self._thread.start()
        
        logger.info(f"✓ Started {target_hours}-hour auto survey")
        log_event("auto_survey", "start", {"target_hours": target_hours, "apply_mode": self.state.get_apply_mode()})
        return True
    
    def stop_survey(self) -> bool:
        """
        Stop running survey and disable file logging
        
        Returns:
            True if stopped successfully
        """
        if not self._running:
            if self.recovery_pending:
                # The survey was waiting to be resumed (receiver not ready):
                # the operator's stop cancels that resume.
                self.recovery_pending = False
                self.state.pause_survey()
                logger.info("Survey stopped while its resume was still pending")
                log_event("auto_survey", "stop", {"reason": "manual_while_resume_pending"})
                return True
            return False

        logger.info("Stopping survey...")
        self._running = False
        
        if self._thread:
            self._thread.join(timeout=5)
        
        self.state.pause_survey()
        
        # Stop file logging to prevent disk space issues
        if self.auto_mode:
            logger.info("Stopping file logging after survey stop...")
            self._stop_file_logging(reason="manual_stop")
        
        logger.info("Survey stopped")
        log_event("auto_survey", "stop", {"reason": "manual"})
        return True
    
    def restart_rtkbase_services(self) -> Dict[str, any]:
        """
        Restart RTKBase str2str services to apply updated coordinates
        
        This should be called after survey completion to ensure
        the new coordinates are loaded by all streaming services.
        
        Returns:
            Dict with restart results
        """
        logger.info("=" * 60)
        logger.info("Restarting RTKBase services to apply new coordinates...")
        
        services_to_restart = [
            'str2str_tcp.service',
            'str2str_ntrip_A.service', 
            'str2str_ntrip_B.service',
            'str2str_rtcm_svr.service',
            'str2str_rtcm_serial.service',
            'str2str_local_ntrip_caster.service'
        ]
        
        restarted = []
        failed = []
        
        for service in services_to_restart:
            try:
                # Check if service is active
                check_result = subprocess.run(
                    ['systemctl', 'is-active', service],
                    capture_output=True,
                    text=True,
                    timeout=5
                )
                
                if check_result.stdout.strip() == 'active':
                    logger.info(f"Restarting {service}...")
                    restart_result = subprocess.run(
                        ['systemctl', 'restart', service],
                        capture_output=True,
                        text=True,
                        timeout=10
                    )
                    
                    if restart_result.returncode == 0:
                        restarted.append(service)
                        logger.info(f"✓ {service} restarted successfully")
                    else:
                        failed.append(service)
                        logger.error(f"✗ Failed to restart {service}: {restart_result.stderr}")
                else:
                    logger.info(f"⊘ {service} not active, skipping")
                    
            except subprocess.TimeoutExpired:
                logger.error(f"✗ Timeout restarting {service}")
                failed.append(service)
            except Exception as e:
                logger.error(f"✗ Error restarting {service}: {e}")
                failed.append(service)
        
        result = {
            'restarted': restarted,
            'failed': failed,
            'success': len(restarted) > 0
        }
        
        if restarted:
            logger.info(f"✓ Successfully restarted {len(restarted)} service(s)")
            logger.info(f"  Services: {', '.join(restarted)}")
        else:
            logger.warning("⚠ No services were restarted!")
        
        if failed:
            logger.warning(f"✗ Failed to restart {len(failed)} service(s): {', '.join(failed)}")
        
        logger.info("=" * 60)
        
        self._services_restarted = len(restarted) > 0
        return result
    

    # UNVERIFIED PLACEHOLDER, not derived from any live PRIDE-PPPAR
    # fixed-vs-degraded comparison on this station (no station access
    # during development - see pride_pppar_processor.py's module
    # docstring for the same caveat on its own AR-related parsing). 90%
    # is a round, conservative-sounding threshold for "AR fix rate good
    # enough to trust this run's position", chosen only
    # because it is clearly above a marginal/mostly-float run and clearly
    # below a clean, fully-fixed one - NOT calibrated against real
    # wl_fix_rate/nl_fix_rate distributions from actual BaseStation PPP-AR
    # runs. Revisit once real fix-rate data has been logged from live
    # finalize-time PPP-AR runs (see _run_ppp_ar()'s logging below).
    #
    # Part 9: split into two SEPARATE named constants (wide-lane vs
    # narrow-lane) instead of one shared PPP_AR_MIN_FIX_RATE_PERCENT -
    # both still 90.0 (the value itself is UNCHANGED, per explicit
    # instruction), but WL and NL fix rates are not the same quantity
    # (narrow-lane resolution is strictly harder and typically converges
    # slower than wide-lane - see pride_pppar_processor.py's AR FIX RATE
    # section), so a future recalibration of one independently of the
    # other no longer requires touching a name that implies they're
    # always the same threshold.
    PPP_AR_MIN_WL_FIX_RATE_PERCENT = 90.0
    PPP_AR_MIN_NL_FIX_RATE_PERCENT = 90.0


    # How often _survey_loop() re-checks str2str_file.service's health (one
    # `systemctl is-active` call) while this survey owns it - the loop
    # itself ticks every 10s, but polling systemctl that often for a
    # service that essentially never needs attention is wasteful; a crash
    # is just as recoverable checked once a minute.
    FILE_LOGGING_HEALTH_CHECK_INTERVAL_SECONDS = 60


    # Marker file name dropped into a slot_* directory to protect it from
    # _cleanup_old_ppp_ar_slot_dirs()'s count-based pruning, regardless of
    # age/count - see _apply_geodetic_position()'s "mark as protected"
    # step and _protect_ppp_ar_dirs()/_unprotect_ppp_ar_dir().
    PROTECTED_SLOT_MARKER = '.protected'

    def _resolve_antenna_calibration(self) -> Dict:
        """
        Part 6a: resolve this station's antenna_info (settings.conf)
        against the ANTEX file currently in use (igs20.atx by default,
        or Part 6b's custom one).

        antenna_calibrated is DERIVED, never a separate manually-set
        config key (per explicit instruction) - "ADVNULLANTENNA", empty,
        or any string not found verbatim as a TYPE/SERIAL NO record in
        the ANTEX file all mean uncalibrated. This also means a station
        whose antenna_info is wrong/stale (e.g. still the settings.conf.
        default placeholder) is automatically treated as uncalibrated,
        not silently given a calibration that doesn't exist.

        Returns: {
            'antenna_type': the configured antenna_info string, as-is
                (not normalized - ANTEX matching is column-exact, so the
                caller passing this straight to _generate_ppp_conf()/
                convbin -ha needs the exact configured string, not a
                "cleaned up" one that might no longer match),
            'antenna_calibrated': bool,
            'antex_path': the ANTEX file path actually checked against,
            'arp_offset': RTKBaseConfig.get_antenna_arp_offset()'s own
                dict ({'height_m', 'east_m', 'north_m'}) - included here
                too since callers resolving antenna calibration
                virtually always also need the ARP offset in the same
                place (both feed the same "process/report at the ARP"
                pipeline).
        }

        Never raises - an ANTEX read failure is treated as "cannot
        verify -> uncalibrated" (see antenna_type_in_antex()'s own
        fail-safe default), since a broken/missing ANTEX file must
        degrade to the safe NONE/uncalibrated path, not block a survey
        update.
        """
        antenna_type = self.rtkbase.get_receiver_info().get('antenna', '')
        # Part 6b: check against the MERGED working ANTEX (igs20.atx +
        # this project's own vendored custom.atx entries, e.g. the
        # ArduSimple AS-ANT3BCAL01 NGS calibration) - not igs20.atx
        # alone, so a station using a custom-calibrated antenna is
        # correctly recognized here, not just inside process_ppp()'s own
        # separate resolve_antex() call.
        antex_path = self.antex.resolve_working_antex()
        calibrated = antenna_type_in_antex(antex_path, antenna_type)
        if not calibrated and antenna_type and antenna_type != 'ADVNULLANTENNA':
            logger.warning(
                f"_resolve_antenna_calibration: configured antenna_info "
                f"{antenna_type!r} was NOT found in {antex_path} - "
                f"treating as uncalibrated (PCO/PCV correction unavailable). "
                f"Verify the exact 20-character IGS/NGS type+radome string, "
                f"or see Part 6b for adding a custom ANTEX entry."
            )
        return {
            'antenna_type': antenna_type,
            'antenna_calibrated': calibrated,
            'antex_path': antex_path,
            'arp_offset': self.rtkbase.get_antenna_arp_offset(),
        }

    def _proposal_reference(self, position: Dict) -> Optional[Dict]:
        """
        The CURRENT broadcast position (settings.conf) and the local
        north/east/up offset of a proposed position from it, for the owner's
        decision. Flat-earth metres, accurate to far better than a
        millimetre at the sub-metre distances this is used for.
        """
        try:
            current = self.rtkbase.get_position()
            if not current:
                return None
            lat0, lon0, h0 = current
            north = (position['lat'] - lat0) * 111132.92
            east = (position['lon'] - lon0) * 111412.84 * math.cos(math.radians(lat0))
            up = position['height'] - h0
            return {
                'lat': lat0, 'lon': lon0, 'height': h0,
                'north_m': north, 'east_m': east, 'up_m': up,
                'horizontal_m': math.hypot(north, east),
            }
        except Exception as e:
            logger.warning(f"_proposal_reference: could not compare with the current position: {e}")
            return None

    def apply_proposal(self, confirmed: bool, force: bool = False) -> Dict:
        """
        Apply the stored proposal of a finished 'propose' survey to the
        broadcast position, after the owner's explicit confirmation. Uses the
        same guarded apply (bounds, jump guard, read-back verification,
        restore on failure, audit) as the CORS position. Returns
        {'ok': bool, 'reason': str|None, 'apply_result': dict|None}.
        """
        if not confirmed:
            return {'ok': False, 'reason': 'confirmation required', 'apply_result': None}
        if self.state.survey_state in (SurveyState.RUNNING, SurveyState.FINALIZING, SurveyState.PAUSED):
            return {'ok': False, 'reason': 'a survey is in progress', 'apply_result': None}
        proposal = self.state.get_status().get('proposal')
        if not isinstance(proposal, dict) or not isinstance(proposal.get('position'), dict):
            return {'ok': False, 'reason': 'no proposal', 'apply_result': None}
        if proposal.get('applied'):
            return {'ok': False, 'reason': 'proposal already applied', 'apply_result': None}
        pos = proposal['position']

        from ..cors_position.cors_apply import apply_position

        result = apply_position(
            self.rtkbase, pos['lat'], pos['lon'], pos['height'],
            source='survey_proposal',
            meta={'created_at': proposal.get('created_at')},
            restart=self.restart_rtkbase_services,
            announce=lambda: _announce_planned_disconnect(self.rtkbase, "auto_survey"),
            force=force,
        )
        if result.get('ok'):
            self.state.mark_proposal_applied()
            self.state.mark_applied({
                'lat': pos['lat'], 'lon': pos['lon'], 'height': pos['height'],
                'broadcast_height_type': pos.get('broadcast_height_type', 'ellipsoidal'),
                'height_ellipsoidal': pos.get('height_ellipsoidal'),
                'height_msl': pos.get('height_msl'),
                'coordinate_system': pos.get('coordinate_system', 'BGS2005'),
            })
            return {'ok': True, 'reason': None, 'apply_result': result}
        return {'ok': False, 'reason': result.get('reason') or 'apply failed', 'apply_result': result}

    def _apply_geodetic_position(self,
                                  lat: float, lon: float, height: float,
                                  obs_file: Path,
                                  is_final: bool,
                                  ppp_backend: str,
                                  position_std: Dict[str, float],
                                  num_epochs: int,
                                  quality_metrics: Dict,
                                  extra_position_fields: Optional[Dict] = None,
                                  ppp_ar_dir: Optional[Path] = None) -> bool:
        """
        Shared geoid-correction / ITRF2020->BGS2005 transform / RTCM
        broadcast / state-update pipeline for the PRIDE-PPPAR final result
        (called from _finalize_survey()).

        Args:
            lat, lon, height: raw geodetic position (ITRF2020/WGS84-family
                datum) BEFORE geoid/BGS2005 processing - PRIDE-PPPAR's
                parse_ppp_ar_result()['lat'/'lon'/'height'].
            obs_file: RINEX observation file this position was derived
                from - needed for extract_observation_epoch() (BGS2005
                transform's t_obs).
            is_final: whether this is the survey's final update.
            ppp_backend: 'pride-pppar' - recorded verbatim in
                the position audit trail dict.
            position_std: dict with std_lat/std_lon/std_height/
                std_h_meters - caller-supplied (PRIDE-PPPAR gives a
                single-point Sx/Sy/Sz, not N/E/U sigmas).
            num_epochs: epoch count for state's num_epochs field (0/1 for
                PRIDE-PPPAR's single-point result).
            quality_metrics: dict merged into state's quality_metrics -
                caller-supplied for the same reason as position_std.
            extra_position_fields: additional keys merged into the
                position dict before it's persisted (e.g. PRIDE-PPPAR's
                ar_wl_fix_rate/ar_nl_fix_rate), or None.
            ppp_ar_dir: the pdp3 work directory (cst_*/amb_*/pos_* - Part
                5's evidence files) this PPP-AR result came from, if any
                (None if unknown). On success, BOTH this directory and obs_file's
                own parent (the rinex slot dir) are marked protected (see
                PROTECTED_SLOT_MARKER) so _cleanup_old_ppp_ar_slot_dirs()
                never prunes the slot(s) that produced the currently-
                applied result, however old they get relative to newer
                slots' count-based retention - the previously-protected
                slot(s), if any, are unprotected first (retrieved from
                the PRIOR applied_position's own recorded dir, if the
                state had one), so protection always tracks exactly the
                CURRENT applied result, not every result ever applied.

        Returns:
            True on success (broadcast applied, state updated), False on
            failure (geoid/BGS2005/broadcast problem - caller should treat
            this the same as any other failed update).
        """
        logger.debug(
            f"_apply_geodetic_position: input point lat={lat}, lon={lon}, "
            f"height={height}, ppp_backend={ppp_backend}, is_final={is_final}, "
            f"obs_file={obs_file}"
        )

        try:
            # Step 6: Compute orthometric (MSL/BGR2005 normal) height via
            # geoid model, for DISPLAY/REPORT purposes only.
            #
            # CORRECTED (reverting a confirmed-live regression - see commit
            # history on this block): RTCM 1005/1006 (Stationary RTK
            # Reference Station ARP) carries the station's ECEF X/Y/Z,
            # derived from lat/lon/ELLIPSOIDAL height. Every connected
            # rover computes its own position as a baseline vector added to
            # this ECEF reference point. Feeding an orthometric
            # (geoid-corrected) height into that reference point - instead
            # of ellipsoidal - adds the full local geoid separation
            # (confirmed ~40m near this station: PPP ellipsoidal height
            # 208.306m vs. BGR2005 normal height ~168m) as a SYSTEMATIC
            # vertical error to every rover's RTK fix, independent of
            # baseline length or observation quality. This is a wire-
            # protocol/ECEF-geometry fact, independent of which horizontal
            # datum (BGS2005, ITRF2020, ...) the lat/lon are expressed in -
            # Инструкция № РД-02-20-25, Чл.22, ал.1 (cited below, Step 7)
            # governs the horizontal reference SYSTEM (BGS2005 vs. raw
            # ITRF/WGS84), not the RTCM height convention, and does not
            # require or imply broadcasting a geoid-corrected height.
            #
            # This was fixed once before (commit ac3d1f6, "stop writing
            # geoid-corrected height into RTCM base reference position")
            # and later reverted (commit 52028a3) on the unsupported claim
            # of an "official АГКК requirement" with no cited source
            # document anywhere in this repo or this change's own commit
            # message - confirmed by searching the whole repo for any
            # АГКК/RD-02-20-25 reference that discusses height convention;
            # none exists beyond this comment's own now-corrected claim.
            #
            # h_ortho (BGR2005 normal height) is still computed and fully
            # recorded (height_msl, below) for display and surveying
            # reports, per Инструкция № РД-02-20-25's actual requirement
            # for a NORMAL height record - it must simply never be the
            # value handed to update_position()/RTCM.
            h_ortho = self.geoid.ellipsoidal_to_orthometric(lat, lon, height)

            if h_ortho is None:
                logger.info("Geoid lookup result: unavailable (no geoid model loaded / position outside grid bounds) - orthometric height unavailable")
            else:
                geoid_sep = height - h_ortho
                logger.info(f"Geoid lookup result: h_ortho={h_ortho:.3f}m (correction {geoid_sep:+.3f}m → Height MSL: {h_ortho:.3f}m)")

            # Step 7: ITRF2020 -> BGS2005 transformation (Part 10b chain:
            # ITRF2020@t_obs -> ETRF2000@t_obs -> BGS2005 = ETRF2000@2005.0,
            # see bgs2005_transformer.py's module docstring). Per Инструкция
            # № РД-02-20-25 от 20.09.2011 г., Чл.22, ал.1: relative GNSS
            # methods (RTK, classified as such in Чл.11) require base
            # station reference coordinates in BGS2005, not raw ITRF/WGS84.
            # The transformed position below - NOT the raw lat/lon/height
            # argument - is what gets broadcast via RTCM.
            t_obs = extract_observation_epoch(obs_file)
            if t_obs is None:
                logger.error("Could not extract observation epoch from RINEX header - "
                             "cannot perform ITRF2020->BGS2005 transformation")
                self.state.record_update_failure("Missing RINEX observation epoch for BGS2005 transform")
                return False

            try:
                bgs2005 = itrf2020_to_bgs2005(
                    GeodeticPoint(lat=lat, lon=lon, height=height),
                    t_obs
                )
            except Exception as e:
                logger.error(f"ITRF2020->BGS2005 transformation failed: {e}", exc_info=True)
                self.state.record_update_failure(f"BGS2005 transformation failed: {e}")
                return False

            logger.info(f"Position estimate (BGS2005, t_obs={t_obs:.4f}): "
                        f"{bgs2005['lat_dd']:.8f}°, {bgs2005['lon_dd']:.8f}°, {bgs2005['height_m']:.3f}m")
            logger.info(f"BGS2005 broadcast coordinate per {bgs2005['regulation_reference']}")
            epoch_red = bgs2005['epoch_reduction']
            logger.info(f"Part 10b epoch reduction: {epoch_red['velocity_source']}, "
                        f"velocity N/E/U={epoch_red['velocity_neu_mm_per_yr']} mm/yr, "
                        f"{epoch_red['from_epoch']:.4f} -> {epoch_red['to_epoch']:.4f} "
                        f"(Δt={epoch_red['dt_years']:.2f}yr)")
            if bgs2005.get('coordinate_provisional'):
                logger.warning(f"PROVISIONAL BGS2005 coordinate: {bgs2005['coordinate_provisional_reason']}")
            logger.debug(f"BGS2005 transform: input={{'lat': {lat}, 'lon': {lon}, 'height': {height}, 't_obs': {t_obs}}}, "
                         f"output={bgs2005}")

            # Step 8: Update RTKBase configuration
            # CORRECTED (see Step 6's comment for the full reasoning):
            # ALWAYS broadcast the BGS2005-transformed ELLIPSOIDAL height
            # (bgs2005['height_m']) - never h_ortho (orthometric/BGR2005
            # normal height). This is the value str2str -p embeds into
            # RTCM 1005/1006 for rover baseline calculations, and the only
            # height type that correctly reconstructs ECEF X/Y/Z from
            # lat/lon/height. broadcast_height_type is now a CONSTANT, not
            # a computed branch - there is no legitimate case where
            # orthometric height should be broadcast, so there is no
            # fallback-vs-default distinction left to make.
            broadcast_height_type = 'ellipsoidal'
            broadcast_height = bgs2005['height_m']

            logger.info(f"RTCM broadcast height type: {broadcast_height_type} "
                        f"({broadcast_height:.3f}m) - BGR2005 normal height "
                        f"{'unavailable' if h_ortho is None else f'{h_ortho:.3f}m'} "
                        f"recorded for display/reports only, never broadcast")

            # DEFENSIVE INVARIANT - the last line of defense against ever
            # repeating the 52028a3 regression (or any future mix-up):
            # verify, right before writing anything that feeds RTCM
            # 1005/1006, that the ECEF computed from what is ACTUALLY about
            # to be written matches the ECEF of the PPP-AR result's own
            # (correct, ellipsoidal-height) point within
            # RTCM_ECEF_SANITY_THRESHOLD_M. A mismatch here means
            # broadcast_height is no longer bgs2005['height_m'] for some
            # reason that got past the constant assignment above (a future
            # edit, an unexpected code path) - refuse to apply rather than
            # ship a silently-wrong base position to every connected rover.
            ecef_check = verify_rtcm_broadcast_ecef(
                GeodeticPoint(lat=lat, lon=lon, height=height), bgs2005,
                bgs2005['lat_dd'], bgs2005['lon_dd'], broadcast_height
            )
            if not ecef_check['ok']:
                error_msg = (f"REFUSED to apply RTCM broadcast position - ECEF sanity check failed: "
                            f"{ecef_check['detail']}. This would have broadcast a position "
                            f"{ecef_check['distance_m']:.3f}m away from the PPP-AR result's own "
                            f"ellipsoidal-height point - almost certainly a height-system mix-up "
                            f"(see survey_controller.py's Step 6/8 comment). Nothing was written "
                            f"to settings.conf/RTCM.")
                logger.error(error_msg)
                self.state.record_update_failure(error_msg)
                return False

            propose_only = self.state.get_apply_mode() == 'propose'
            if propose_only:
                logger.info("🎯 FINAL RESULT (propose mode) - the broadcast position is NOT changed; "
                            "the result is stored as a proposal awaiting the owner's confirmation")
                update_ok = True
            else:
                logger.info("🎯 FINAL UPDATE - Applying permanent coordinates (BGS2005)...")
                update_ok = self.rtkbase.update_position(bgs2005['lat_dd'], bgs2005['lon_dd'], broadcast_height)

            if propose_only:
                pass
            elif update_ok:
                logger.info(f"✓ RTCM broadcast: final configuration applied successfully "
                            f"(lat={bgs2005['lat_dd']:.8f}, lon={bgs2005['lon_dd']:.8f}, height={broadcast_height:.3f})")

                # Restart services so the new coordinates take effect immediately
                try:
                    _announce_planned_disconnect(self.rtkbase, "auto_survey")
                    restart_result = self.restart_rtkbase_services()
                    if not restart_result.get('success', False):
                        logger.warning("Service restart reported failure during update")
                except Exception as restart_err:
                    logger.error(f"Service restart after update failed: {restart_err}")
            else:
                logger.error(
                    f"✗ RTCM broadcast: rtkbase.update_position() failed "
                    f"(lat={bgs2005['lat_dd']:.8f}, lon={bgs2005['lon_dd']:.8f}, height={broadcast_height:.3f}) - "
                    f"settings.conf was not updated"
                )
                self.state.record_update_failure("Failed to update RTKBase settings.conf")
                return False

            # Step 9: Update state
            # Explicit float() casts: keep numpy.float64 out of the
            # JSON-serialized state - this method owns that boundary.
            #
            # position['height'] holds the height ACTUALLY BROADCAST this
            # update (broadcast_height, Step 8 above - ALWAYS ellipsoidal,
            # see that step's comment) - the value actually written to
            # settings.conf/RTCM. 'height_ellipsoidal' is the same value,
            # kept as an explicitly-named duplicate so a consumer never has
            # to assume what 'height' means; 'height_msl' (BGR2005 normal
            # height, display/report only, never broadcast) is recorded
            # alongside it whenever the geoid model could compute it. The
            # raw ITRF2020 estimate is likewise kept for display/
            # diagnostics only, never re-broadcast.
            position = {
                'lat': float(bgs2005['lat_dd']),
                'lon': float(bgs2005['lon_dd']),
                'height': float(broadcast_height),  # ACTUALLY BROADCAST - always ellipsoidal (GRS80), see Step 8
                'broadcast_height_type': broadcast_height_type,  # always 'ellipsoidal' - kept as an explicit audit-trail field, not a runtime choice
                'height_ellipsoidal': float(bgs2005['height_m']),  # BGS2005 ellipsoidal (GRS80) - identical to 'height' above; named explicitly to avoid ambiguity
                'height_msl': float(h_ortho) if h_ortho is not None else None,  # BGR2005 normal height - DISPLAY/REPORT ONLY, never broadcast
                'coordinate_system': 'BGS2005',
                'itrf2020_lat': float(lat),
                'itrf2020_lon': float(lon),
                'itrf2020_height': float(height),
                # Part 10b: all three chain stages, explicitly labeled,
                # for display/reports only - the broadcast decision above
                # (lat/lon/height) is unaffected by these. See
                # bgs2005_transformer.py's itrf2020_to_bgs2005() docstring.
                'etrf2000_t_obs': {
                    'lat': float(bgs2005['etrf2000_t_obs']['lat_dd']),
                    'lon': float(bgs2005['etrf2000_t_obs']['lon_dd']),
                    'height': float(bgs2005['etrf2000_t_obs']['height_m']),
                    'epoch': float(bgs2005['etrf2000_t_obs']['epoch']),
                },
                'epoch_reduction': {
                    'velocity_neu_mm_per_yr': bgs2005['epoch_reduction']['velocity_neu_mm_per_yr'],
                    'velocity_source': bgs2005['epoch_reduction']['velocity_source'],
                    'velocity_is_station_specific': bgs2005['epoch_reduction']['velocity_is_station_specific'],
                    'from_epoch': float(bgs2005['epoch_reduction']['from_epoch']),
                    'to_epoch': float(bgs2005['epoch_reduction']['to_epoch']),
                    'dt_years': float(bgs2005['epoch_reduction']['dt_years']),
                },
                'coordinate_provisional': bgs2005.get('coordinate_provisional', False),
                'coordinate_provisional_reason': bgs2005.get('coordinate_provisional_reason'),
                # Which PPP backend produced the broadcast lat/lon/height
                # above (always 'pride-pppar'; kept for the audit trail).
                'ppp_backend': ppp_backend,
            }

            # Part 6a: recover the MARKER position (survey point) from
            # this ARP-computed broadcast result, for reports/display
            # ONLY - see arp_to_marker()'s own docstring and bgs2005_
            # transformer.py's "PART 6a RESOLUTION" comment for why this
            # never feeds back into the broadcast position itself. A
            # zero ARP offset (not yet configured/measured, or a genuine
            # zero-offset antenna mount) makes marker == ARP exactly, so
            # this is always safe to compute and report even before an
            # operator has entered a real offset.
            try:
                arp_offset = self.rtkbase.get_antenna_arp_offset()
                marker = arp_to_marker(position['lat'], position['lon'], position['height'], arp_offset)
                marker_check = verify_arp_to_marker_offset(
                    position['lat'], position['lon'], position['height'], arp_offset, marker)
                if not marker_check['ok']:
                    logger.warning(f"_apply_geodetic_position: ARP-to-marker reconciliation "
                                   f"check failed: {marker_check['detail']} - marker position "
                                   f"below may not be trustworthy for reports (broadcast "
                                   f"position is unaffected - this never touches RTCM).")
                position['marker_lat'] = marker['lat']
                position['marker_lon'] = marker['lon']
                position['marker_height'] = marker['height']
                position['antenna_arp_offset'] = arp_offset
            except Exception as e:
                logger.warning(f"_apply_geodetic_position: failed to compute marker position "
                               f"from ARP offset: {e} - marker_lat/lon/height omitted from this "
                               f"update (broadcast position is unaffected)")

            if extra_position_fields:
                position.update(extra_position_fields)

            self.state.update_progress(
                position=position,
                position_std=position_std,
                num_epochs=num_epochs,
                quality_metrics=quality_metrics
            )

            if propose_only:
                self.state.record_proposal(position, self._proposal_reference(position))

            # Protect the slot dir(s) that produced this ACCEPTED result
            # from _cleanup_old_ppp_ar_slot_dirs()'s count-based pruning -
            # see PROTECTED_SLOT_MARKER's own comment and this method's
            # ppp_ar_dir docstring. obs_file.parent is the rinex slot dir
            # for BOTH backends; ppp_ar_dir (cst_*/amb_*/pos_* evidence)
            # only exists for the PRIDE-PPPAR path. Best-effort: a
            # protection failure must never fail the update itself, it
            # only means a future prune pass might remove this evidence
            # sooner than ideal.
            try:
                self._protect_slot_dir(obs_file.parent)
                if ppp_ar_dir is not None:
                    self._protect_slot_dir(ppp_ar_dir)
            except Exception as e:
                logger.warning(f"_apply_geodetic_position: failed to protect slot dir(s) "
                               f"for this accepted result: {e}")

            logger.info(f"✓ FINAL UPDATE complete ({ppp_backend}) - Epochs: {num_epochs}")

            return True

        except Exception as e:
            logger.error(f"Failed to apply geodetic position: {e}", exc_info=True)
            try:
                self.state.record_update_failure(f"Unhandled exception: {e}")
            except Exception:
                pass
            return False

    
    # How many PROTECTED slot dirs (see PROTECTED_SLOT_MARKER) to allow to
    # accumulate before the OLDEST protected ones are pruned too - a
    # protected dir is never removed by the normal count/age rule, so
    # without SOME cap, every survey's worth of accepted interim updates
    # (potentially dozens over a multi-day survey) would pile up
    # protected forever. A handful is enough to always have the CURRENT
    # applied result's evidence (and the immediately preceding one or
    # two, useful when comparing a just-superseded result) without ever
    # approaching the unbounded growth this whole retention effort exists
    # to prevent.
    PROTECTED_SLOT_DIRS_TO_KEEP = 3

    def _protect_slot_dir(self, slot_dir: Path) -> None:
        """
        Drop PROTECTED_SLOT_MARKER into slot_dir, exempting it from
        _cleanup_old_ppp_ar_slot_dirs()'s count/age-based pruning - see
        _apply_geodetic_position()'s "protect the slot dir(s)" step.
        A no-op (logged, not raised) if slot_dir doesn't exist - the
        caller's own update already succeeded by this point; a failure
        to protect its evidence afterward must never undo that.
        """
        if not slot_dir.is_dir():
            logger.warning(f"_protect_slot_dir: {slot_dir} is not a directory - cannot protect")
            return
        (slot_dir / self.PROTECTED_SLOT_MARKER).touch()

    # Number of past per-slot PRIDE-PPPAR work directories to retain (see
    # _run_ppp_ar()'s isolated-work_dir scheme) - kept around for
    # postmortem debugging of a failed slot (obs file, downloaded
    # products, full pdp3 output if ever dumped to disk), pruned beyond
    # this count so a long-running survey (or repeated surveys on the same
    # station) doesn't accumulate unbounded disk usage. Deliberately NOT 1
    # - a single retained slot would be overwritten/deleted before an
    # operator has a chance to look at it if a NEW slot starts running
    # (e.g. investigating slot N's failure while slot N+1 is already in
    # progress); keeping several days' worth of slots (at 4h cadence, 10
    # slots ~= 40h ~= the common failure-investigation window) costs only
    # a few RINEX/product files each, not the multi-day accumulation this
    # fix is replacing.
    PPP_AR_SLOT_DIRS_TO_KEEP = 10

    @staticmethod
    def _dir_size_bytes(path: Path) -> int:
        """
        Total size of every regular file under path, recursively.
        Best-effort: a file that vanishes mid-walk (e.g. pruned by a
        concurrent call) is simply skipped, not an error - this is a
        disk-usage ESTIMATE for logging, not an exact accounting that
        anything downstream depends on.
        """
        total = 0
        for f in path.rglob('*'):
            try:
                if f.is_file():
                    total += f.stat().st_size
            except OSError:
                continue
        return total

    def _cleanup_old_ppp_ar_slot_dirs(self, ppp_ar_root: Path, keep_dir: Path) -> None:
        """
        Prune old per-slot work directories under ppp_ar_root (PRIDE-PPPAR).

        PROTECTED dirs (containing PROTECTED_SLOT_MARKER - written by
        _apply_geodetic_position() for the slot(s) that produced the
        CURRENTLY APPLIED result, see _protect_slot_dir()) are counted
        and pruned SEPARATELY from ordinary ones: they are exempt from
        the normal age-based PPP_AR_SLOT_DIRS_TO_KEEP rule entirely (an
        applied result's own evidence must never be pruned just because
        enough newer slots have since run, however old it gets), subject
        only to their own, much smaller PROTECTED_SLOT_DIRS_TO_KEEP cap
        (oldest-protected-first) so that count alone cannot grow
        unbounded either.

        Ordinary (unprotected) dirs keep the PPP_AR_SLOT_DIRS_TO_KEEP
        most-recently-created ones (by directory mtime) plus keep_dir
        itself (the one about to be used for the current attempt, so
        it's never pruned even if it happens to already exist and be
        older than others - shouldn't normally happen given the run-id
        suffix, but kept defensive).

        RETENTION (rule 3 of the Part 4b/5-era proposal): logs the
        directory count and total size under ppp_ar_root, both BEFORE and
        AFTER this pruning pass, at INFO whenever anything was actually
        pruned (silent otherwise, to avoid a log line on every single
        update when there is nothing to prune yet) - so disk growth under
        work_dir is visible from normal logs, not only discoverable by
        manually `du`-ing the station after the fact.

        Best-effort only: any failure to list/remove a stale directory is
        logged and otherwise ignored - a pruning failure must never abort
        or fail the underlying update/PPP-AR run itself.
        """
        try:
            if not ppp_ar_root.is_dir():
                return
            all_slot_dirs = [
                p for p in ppp_ar_root.iterdir()
                if p.is_dir() and p.name.startswith("slot_") and p != keep_dir
            ]
            protected_dirs = [p for p in all_slot_dirs if (p / self.PROTECTED_SLOT_MARKER).exists()]
            unprotected_dirs = [p for p in all_slot_dirs if p not in protected_dirs]

            protected_dirs.sort(key=lambda p: p.stat().st_mtime, reverse=True)
            unprotected_dirs.sort(key=lambda p: p.stat().st_mtime, reverse=True)

            to_prune = (
                protected_dirs[self.PROTECTED_SLOT_DIRS_TO_KEEP:] +
                unprotected_dirs[self.PPP_AR_SLOT_DIRS_TO_KEEP:]
            )
            if not to_prune:
                return

            size_before = self._dir_size_bytes(ppp_ar_root)
            count_before = len(all_slot_dirs) + 1  # +1 for keep_dir

            removed = 0
            for stale_dir in to_prune:
                try:
                    shutil.rmtree(stale_dir)
                    logger.debug(f"_cleanup_old_ppp_ar_slot_dirs: removed stale slot dir {stale_dir}")
                    removed += 1
                except Exception as e:
                    logger.warning(f"_cleanup_old_ppp_ar_slot_dirs: failed to remove stale slot dir {stale_dir}: {e}")

            size_after = self._dir_size_bytes(ppp_ar_root)
            logger.info(
                f"_cleanup_old_ppp_ar_slot_dirs({ppp_ar_root}): pruned {removed}/{len(to_prune)} "
                f"stale slot dir(s) - {count_before} -> {count_before - removed} dirs, "
                f"{size_before / 1024 / 1024:.1f}MB -> {size_after / 1024 / 1024:.1f}MB"
            )
        except Exception as e:
            logger.warning(f"_cleanup_old_ppp_ar_slot_dirs: pruning failed (non-fatal): {e}")


    # Loose (non-slot_*) files directly in work_dir/rinex/ older than this
    # many days are removed by _cleanup_legacy_rinex_root_files() - see
    # that method's docstring. 7 days is generous: these files are
    # derived data (reproducible from data/'s raw archives, never the
    # only copy of anything), and this cleanup only runs at survey start,
    # so even a slow-to-notice station still gets them cleared well
    # before they could meaningfully contribute to a disk-space problem.
    LEGACY_RINEX_FILE_AGE_DAYS = 7


    def _run_ppp_ar(self, slot_label: str = "unknown",
                    window_end: Optional[datetime] = None) -> Optional[Dict]:
        """
        `window_end` (naive UTC) freezes the END of the processed window; the
        FINAL run passes survey start + target duration so a retry hours
        later still processes exactly [start, start+target]. None (interim
        slots) means "up to now".

        Run PRIDE-PPPAR (pdp3) for ambiguity-resolved PPP-static
        positioning - the worker behind the final result
        (_finalize_survey()).

        Independently re-locates/re-converts EVERY raw GNSS log segment
        covering [survey start, now] to RINEX - self.rtkbase.
        get_data_files_since() and self.rinex.convert_raw_files_to_rinex_obs()
        are idempotent lookups/conversions against the same window each
        time, so redoing them here on every call is cheap and keeps this
        method fully self-contained.

        RAW-LOG ROTATION (fix for a confirmed-live bug): str2str rotates
        its raw log file every file_rotate_time (typically '24' = UTC
        midnight), starting a brand-new file and leaving the previous one
        closed in data_dir (or later zipped by archive_and_clean.sh).
        get_data_files_since() follows the window across any number of
        such rotations - and extracts a matching zipped segment back out
        if archive_and_clean.sh already ran - so each attempt still
        converts the WHOLE survey-so-far window into one continuous RINEX
        obs file (via rinex_converter.merge_rinex_obs() when more than one
        segment is involved), instead of silently processing only the
        data written since the most recent rotation.

        Args:
            slot_label: identifies which slot/attempt this is ("0h", "4h",
                "final", ...) - used ONLY to build this run's isolated
                PRIDE-PPPAR work directory (see below) and for logging;
                has no effect on the actual PPP-AR computation.

        ISOLATED WORK DIRECTORY (fix for a confirmed-live hazard):
        each call gets its OWN pdp3 work directory
        (work_dir/pride_pppar/slot_<slot_label>_<run_id>/), instead of the
        single shared work_dir/pride_pppar/ directory previously reused
        for an entire survey AND across separate survey runs on different
        calendar days. Confirmed live on BaseStation: that shared
        directory accumulated .obs files from 4 different dates plus TWO
        different brdm*.p broadcast nav files simultaneously, with a MIX
        of root-owned files (current run) and non-root-owned leftovers
        from an earlier/different-context run (a prior run's obs/product
        files that the current, root-run pdp3 invocation could not even
        overwrite - "touch: Permission denied" confirmed live) sitting in
        the exact directory every 4h slot's pdp3 invocation runs from.
        Giving each attempt a fresh, uniquely-named directory means no
        stale multi-day state or ownership mismatch can ever be present
        when pdp3 starts, and _cleanup_old_ppp_ar_slot_dirs() prunes old
        ones (keeping PPP_AR_SLOT_DIRS_TO_KEEP for postmortem debugging)
        so this doesn't grow unbounded.

        Returns:
            Dict from PridePpparProcessor.parse_ppp_ar_result()
            (lat/lon/height/sig0/nobs/wl_fix_rate/nl_fix_rate/...), PLUS
            an 'obs_file' key (the RINEX obs file this result was derived
            from - needed by callers for _apply_geodetic_position()'s
            BGS2005 t_obs extraction), on success. None if PRIDE-PPPAR is
            not installed, no raw data is available yet, the run failed,
            or no usable result could be parsed - NEVER raises; callers
            must treat None as "skip this run", not as a fatal error.
        """
        logger.info(f"_run_ppp_ar: starting PRIDE-PPPAR run (slot={slot_label})")

        # Context of THIS run for the attempt record: when the run fails the
        # caller gets None, and without this the persisted record loses the
        # frequency combination pdp3 was given, the obs duration and the
        # stage that failed (see _build_ppp_ar_attempt_record()).
        self._last_ppp_ar_run_context = {
            'stage': 'start', 'frequency_selection': None, 'obs_duration_minutes': None,
            'failure_kind': None,
        }

        try:
            pride = PridePpparProcessor(rtkbase_root=self.rtkbase.rtkbase_root)
        except Pdp3NotFoundError as e:
            logger.warning(f"_run_ppp_ar: PPP-AR enabled but pdp3 not available - skipping this run: {e}")
            self._last_ppp_ar_run_context['stage'] = 'pdp3_unavailable'
            return None

        # Window = [survey start, now] - the WHOLE survey so far, not just
        # since the latest str2str rotation. get_data_file() (single
        # latest file only) used to be used here: after a UTC-midnight
        # raw-log rotation (file_rotate_time, typically '24'), every
        # interim slot running after that point would silently process
        # only the data written since the rotation, not the full window
        # this slot/finalize step is actually supposed to cover - see
        # get_data_files_since()'s own docstring for the full reasoning,
        # including the archive_and_clean.sh zip-extraction case.
        status = self.state.get_status()
        survey_start_raw = status.get('start_time')
        survey_start_time = datetime.fromisoformat(survey_start_raw) if survey_start_raw else datetime.utcnow()

        # Isolated per-attempt rinex_dir (own run_id, independent of the
        # pdp3 work dir's run_id further below - same scheme, different
        # timestamp, both unique) - the old self.work_dir / "rinex" was a
        # SINGLE directory shared across
        # every _run_ppp_ar() call for the entire survey; converting
        # multiple raw segments per call (now routine whenever a rotation
        # falls inside the window) makes that an active hazard, not just
        # a latent one: convert_raw_to_rinex_obs() picks the newest *.obs
        # file in whatever directory it's given BY MTIME, so a shared
        # directory could pick up a previous call's leftover output
        # instead of this call's own result.
        safe_slot_label = re.sub(r'[^A-Za-z0-9_.-]', '_', str(slot_label))
        run_id = f"{datetime.utcnow().strftime('%Y%m%dT%H%M%SZ')}_{os.getpid()}"
        rinex_dir = self.work_dir / "rinex" / f"slot_{safe_slot_label}_{run_id}"

        extract_dir = rinex_dir / "_extracted_from_zip"
        raw_files = self.rtkbase.get_data_files_since(survey_start_time, extract_dir=extract_dir,
                                                      end_time=window_end)
        if not raw_files:
            logger.warning("_run_ppp_ar: no raw data file found - skipping this run")
            self._last_ppp_ar_run_context['stage'] = 'no_raw_data'
            return None

        logger.debug(f"_run_ppp_ar: raw_files={raw_files}")

        # Part 6a: antenna type (ANTEX-verified) + receiver model/firmware
        # populated into the RINEX header for pdp3, which reads ANT # /
        # TYPE directly from it (confirmed: pdp3.sh's CheckAntennaInAtx
        # pre-flight check, and no separate antenna-delta CLI override
        # exists for pdp3 at all) - zero_antenna_delta=True so pdp3
        # always processes at the antenna's own ARP, never a stale/wrong
        # marker-offset value that happened to already be in the header.
        antenna = self._resolve_antenna_calibration()
        receiver_info = self.rtkbase.get_receiver_info()
        receiver_hr = f"/{receiver_info.get('model', '')}/{receiver_info.get('firmware', '')}"
        # time_start trims segments that began before the survey (e.g. a
        # file left running by the File service before the survey started).
        rinex_result = self.rinex.convert_raw_files_to_rinex_obs(
            raw_files, rinex_dir,
            antenna_type=antenna['antenna_type'] if antenna['antenna_calibrated'] else None,
            receiver_info=receiver_hr,
            zero_antenna_delta=True,
            time_start=survey_start_time,
            time_end=window_end,
            sample_interval=PPP_AR_SAMPLE_INTERVAL_S,
        )
        if not rinex_result:
            logger.warning("_run_ppp_ar: RINEX conversion failed - skipping this run")
            self._last_ppp_ar_run_context['stage'] = 'rinex_conversion_failed'
            return None

        obs_file, _nav_file = rinex_result

        # Observation duration is critical context for interpreting ANY
        # PPP-AR result (success or failure) - PRIDE-PPPAR convergence
        # needs 8h+, so logging this on every attempt (not just success)
        # is what makes a short/failed run diagnosable from logs alone.
        try:
            obs_duration_minutes = extract_observation_duration_minutes(obs_file)
        except Exception as e:
            logger.warning(f"_run_ppp_ar: failed to compute observation duration from {obs_file}: {e}")
            obs_duration_minutes = None
        self._last_ppp_ar_run_context['obs_duration_minutes'] = obs_duration_minutes

        logger.info(
            f"_run_ppp_ar: obs_file={obs_file}, "
            f"obs_duration={obs_duration_minutes:.1f}min" if obs_duration_minutes is not None
            else f"_run_ppp_ar: obs_file={obs_file}, obs_duration=unknown (could not read RINEX header epochs)"
        )

        # Isolated per-attempt work directory - see this method's docstring
        # for why the old single shared work_dir/pride_pppar/ directory
        # was a confirmed-live hazard (stale multi-day obs/product files,
        # root/non-root ownership mismatches). run_id combines a UTC
        # timestamp with the process id so two attempts started in the
        # same second (shouldn't happen given the 4h/final schedule, but
        # cheap insurance) never collide.
        ppp_ar_root = self.work_dir / "pride_pppar"
        safe_slot_label = re.sub(r'[^A-Za-z0-9_.-]', '_', str(slot_label))
        run_id = f"{datetime.utcnow().strftime('%Y%m%dT%H%M%SZ')}_{os.getpid()}"
        ppp_ar_dir = ppp_ar_root / f"slot_{safe_slot_label}_{run_id}"
        logger.info(f"_run_ppp_ar: isolated work_dir for this attempt: {ppp_ar_dir}")

        pos_file = pride.process_ppp_ar(
            obs_file, work_dir=ppp_ar_dir,
            custom_antex_path=self.antex.resolve_augmented_custom_antex(),
        )
        # The combination is chosen inside process_ppp_ar() before pdp3 runs,
        # so it is known even when pdp3 itself fails.
        self._last_ppp_ar_run_context['frequency_selection'] = getattr(pride, '_last_freq_selection', None)
        self._last_ppp_ar_run_context['failure_kind'] = getattr(pride, '_last_failure_kind', None)

        # Prune old slot directories AFTER this attempt (whether it
        # succeeded or failed) - never before, so a failed attempt's own
        # directory is never at risk of being pruned by its own cleanup
        # pass, and always runs regardless of outcome so failed-attempt
        # directories don't escape the retention limit either.
        self._cleanup_old_ppp_ar_slot_dirs(ppp_ar_root, keep_dir=ppp_ar_dir)
        # Same pruning for the per-attempt rinex_dir created above
        # (work_dir/rinex/slot_<label>_<run_id>/) - this is a SEPARATE
        # accumulation point from ppp_ar_root (added by the
        # get_data_files_since()/convert_raw_files_to_rinex_obs()
        # rotation fix) that would otherwise grow unbounded across a
        # multi-day survey exactly like ppp_ar_root once did before this
        # same generic cleanup existed - reused here rather than adding a
        # second, near-identical pruning method.
        self._cleanup_old_ppp_ar_slot_dirs(rinex_dir.parent, keep_dir=rinex_dir)

        if not pos_file:
            logger.warning(
                f"_run_ppp_ar: pdp3 run failed or produced no result - skipping this run "
                f"(obs_duration={obs_duration_minutes:.1f}min)" if obs_duration_minutes is not None
                else "_run_ppp_ar: pdp3 run failed or produced no result - skipping this run (obs_duration=unknown)"
            )
            self._last_ppp_ar_run_context['stage'] = 'pdp3_failed'
            return None

        result = pride.parse_ppp_ar_result(pos_file)
        if not result:
            logger.warning(
                f"_run_ppp_ar: could not parse pdp3 result - skipping this run "
                f"(obs_duration={obs_duration_minutes:.1f}min)" if obs_duration_minutes is not None
                else "_run_ppp_ar: could not parse pdp3 result - skipping this run (obs_duration=unknown)"
            )
            self._last_ppp_ar_run_context['stage'] = 'parse_failed'
            return None

        logger.info(f"_run_ppp_ar: result: {result['lat']:.8f}°, {result['lon']:.8f}°, "
                    f"{result['height']:.3f}m, "
                    f"wl_fix_rate={result['wl_fix_rate']}, "
                    f"nl_fix_rate={result['nl_fix_rate']}, sig0={result['sig0']}, "
                    f"obs_duration={obs_duration_minutes:.1f}min" if obs_duration_minutes is not None
                    else f"_run_ppp_ar: result: {result['lat']:.8f}°, {result['lon']:.8f}°, "
                         f"{result['height']:.3f}m, "
                         f"wl_fix_rate={result['wl_fix_rate']}, "
                         f"nl_fix_rate={result['nl_fix_rate']}, sig0={result['sig0']}, "
                         f"obs_duration=unknown")

        result['obs_file'] = obs_file
        result['obs_duration_minutes'] = obs_duration_minutes
        # Part 1's per-run frequency-combination choice (select_frequency_
        # combination(), called inside process_ppp_ar() itself) - stashed
        # on the SAME PridePpparProcessor instance that just ran, so no
        # second obs-file read is needed to recover it.
        result['frequency_selection'] = getattr(pride, '_last_freq_selection', None)
        # Retention follow-up: the pdp3 work dir itself (cst_*/amb_*/pos_*
        # evidence), so _apply_geodetic_position() can protect it from
        # pruning if this result ends up being the one that's applied -
        # see that method's ppp_ar_dir arg and PROTECTED_SLOT_MARKER.
        result['ppp_ar_dir'] = ppp_ar_dir

        # Part 6b (item 3): per-band calibration status for the bands
        # THIS run's frequency_selection actually chose - "calibrated"
        # (a real ANTEX entry), "substituted from Gxx"
        # (augment_antex_with_gps_substitutes() filled it in), or "none"
        # (missing even after augmentation). Logged at INFO on every
        # attempt and carried into the Part 5 attempt record/Autosurvey
        # UI - see _build_ppp_ar_attempt_record()/
        # _ppp_ar_extra_position_fields().
        if result['frequency_selection'] and result['frequency_selection'].get('frq'):
            try:
                band_calibration = classify_band_calibration(
                    self.antex.resolve_augmented_custom_antex(),
                    result['frequency_selection']['frq'],
                )
                result['band_calibration'] = band_calibration
                logger.info(f"_run_ppp_ar: per-band calibration status: {band_calibration}")
            except Exception as e:
                logger.warning(f"_run_ppp_ar: failed to classify per-band calibration status: {e}")
                result['band_calibration'] = None
        else:
            result['band_calibration'] = None

        return result

    def _ppp_ar_fix_rate_ok(self, ppp_ar_result: Dict) -> bool:
        """
        Whether a PRIDE-PPPAR result's wide-lane/narrow-lane fix rates
        both clear their respective PPP_AR_MIN_WL_FIX_RATE_PERCENT /
        PPP_AR_MIN_NL_FIX_RATE_PERCENT thresholds - shared check used by
        _finalize_survey().

        wl_fix_rate/nl_fix_rate come from _parse_fix_rate_line()'s
        combined multi-GNSS aggregate stdout line, now confirmed
        (Part 9) to correctly take the LAST such line rather than the
        first, which matters specifically for multi-constellation AR
        (QZSS prints an identically-prefixed line of its own before the
        true aggregate - see that function's own comment).

        Part 9 reconciliation: also cross-checks these percentages
        against Part 5's amb_fixing (cst_* T/W/N) data, when available,
        as a sanity check that the two independent parses of pdp3's
        output agree - cst_file's 'combined' dict carries the SAME
        underlying counts (total/wide_fixed/narrow_fixed) the stdout
        line's percentages are themselves computed from (see arsig.f90:
        wl_pct = wide_fixed/total*100, nl_pct = narrow_fixed/wide_fixed*100),
        so a mismatch here would mean one of the two parsers has a bug,
        not a real AR discrepancy. Logged, AND recorded into
        ppp_ar_result['fix_rate_mismatch'] (mutated in place - this
        method's caller holds the same dict reference and passes it on
        to _log_ppp_ar_attempt()/_build_ppp_ar_attempt_record(), so the
        mismatch shows up in that attempt's persisted Part 5 record and
        on the Autosurvey page) - but NEVER itself gates the accept/
        reject decision (that stays wl_fix_rate/nl_fix_rate from the
        stdout line, unchanged) - amb_fixing can legitimately be absent
        (AR not attempted this run) when wl_fix_rate/nl_fix_rate still
        exist from the stdout line, so it is corroborating evidence
        only, not a second independent gate.
        """
        wl = ppp_ar_result.get('wl_fix_rate')
        nl = ppp_ar_result.get('nl_fix_rate')
        ok = (
            wl is not None and nl is not None and
            wl >= self.PPP_AR_MIN_WL_FIX_RATE_PERCENT and
            nl >= self.PPP_AR_MIN_NL_FIX_RATE_PERCENT
        )

        reconciliation = ""
        amb_fixing = ppp_ar_result.get('amb_fixing')
        combined = amb_fixing.get('combined') if amb_fixing else None
        if combined and combined.get('total'):
            total, wide_fixed, narrow_fixed = combined['total'], combined['wide_fixed'], combined['narrow_fixed']
            cst_wl_pct = wide_fixed * 100.0 / total
            cst_nl_pct = (narrow_fixed * 100.0 / wide_fixed) if wide_fixed else 0.0
            reconciliation = (
                f" | cst_* cross-check: T={total} W={wide_fixed} N={narrow_fixed} "
                f"-> wl={cst_wl_pct:.1f}% nl={cst_nl_pct:.1f}%"
            )
            if wl is not None and nl is not None and \
               (abs(cst_wl_pct - wl) > 0.1 or abs(cst_nl_pct - nl) > 0.1):
                logger.warning(
                    f"_ppp_ar_fix_rate_ok: stdout fix rate (wl={wl}%, nl={nl}%) "
                    f"disagrees with cst_* file's own counts (wl={cst_wl_pct:.1f}%, "
                    f"nl={cst_nl_pct:.1f}%) by more than 0.1% - one of the two "
                    f"parsers likely has a bug (see this method's docstring); "
                    f"the stdout-derived values are still what gates this decision."
                )
                ppp_ar_result['fix_rate_mismatch'] = {
                    'stdout_wl_fix_rate': wl,
                    'stdout_nl_fix_rate': nl,
                    'cst_wl_fix_rate': cst_wl_pct,
                    'cst_nl_fix_rate': cst_nl_pct,
                }

        logger.info(
            f"_ppp_ar_fix_rate_ok: wl={wl if wl is not None else 'n/a'}% "
            f"(need >= {self.PPP_AR_MIN_WL_FIX_RATE_PERCENT}%), "
            f"nl={nl if nl is not None else 'n/a'}% "
            f"(need >= {self.PPP_AR_MIN_NL_FIX_RATE_PERCENT}%) -> "
            f"{'OK' if ok else 'BELOW THRESHOLD'}{reconciliation}"
        )
        return ok

    def _ppp_ar_extra_position_fields(self, ppp_ar_result: Dict) -> Dict:
        """
        Part 5 quality-evidence fields merged into position/
        applied_position for an ACCEPTED PPP-AR update
        (_apply_geodetic_position()'s extra_position_fields) - the SAME
        fields _build_ppp_ar_attempt_record() persists for every attempt
        regardless of outcome, kept here as the single place both an
        accepted update's audit trail and the attempt-history record
        pull from, so the two can never drift apart on what "the
        evidence for this result" actually means.
        """
        return {
            'ar_wl_fix_rate': ppp_ar_result.get('wl_fix_rate'),
            'ar_nl_fix_rate': ppp_ar_result.get('nl_fix_rate'),
            'ar_product_tier': ppp_ar_result.get('product_tier'),
            'ar_amb_fixing': ppp_ar_result.get('amb_fixing'),
            'ar_amb_resolvable': ppp_ar_result.get('amb_resolvable'),
            'ar_frequency_selection': ppp_ar_result.get('frequency_selection'),
            'ar_processed_window': ({
                'first_epoch': ppp_ar_result['processed_window']['first_epoch'].isoformat(),
                'last_epoch': ppp_ar_result['processed_window']['last_epoch'].isoformat(),
                'processed_minutes': ppp_ar_result['processed_window']['processed_minutes'],
            } if ppp_ar_result.get('processed_window') is not None else None),
            'ar_fix_rate_mismatch': ppp_ar_result.get('fix_rate_mismatch'),
            'ar_band_calibration': ppp_ar_result.get('band_calibration'),
        }

    def _ppp_ar_failure_info(self, stage: Optional[str] = None) -> Dict:
        """
        Classified failure (error_class / reason, see
        ppp_ar_failure.describe_failure()) for the PPP-AR run that just
        failed. `stage` overrides the stage recorded by _run_ppp_ar() (used
        for failures after a successful pdp3 run: fix-rate gate, apply).
        """
        ctx = getattr(self, '_last_ppp_ar_run_context', None) or {}
        if stage is None:
            stage = ctx.get('stage')
        kind = ctx.get('failure_kind') if stage == STAGE_PDP3_FAILED else None
        return describe_failure(stage, kind)

    def _log_ppp_ar_attempt(self, slot_label: str, result: str, reason: str,
                             ppp_ar_result: Optional[Dict] = None,
                             failure_info: Optional[Dict] = None) -> None:
        """
        Log one single-line, grep-able PPP-AR attempt summary, fired from
        EVERY return path of the
        finalize-time PPP-AR block in _finalize_survey() - success, skip,
        or failure alike. Exact shape (per this session's explicit
        instruction):

            PPP-AR ATTEMPT slot=<Xh|final> result=<SUCCESS|SKIPPED|FAILED> reason=<short reason> obs_duration=<Ymin or 'unknown'> wl_fix=<value or 'n/a'> nl_fix=<value or 'n/a'> sig0=<value or 'n/a'>

        Also stashes the summary on self._last_ppp_ar_attempt_summary so
        _finalize_survey()'s "No final position computed" error path (see
        that method) can include the LAST PPP-AR-specific failure reason
        instead of a generic, disconnected-from-cause message - this is
        exactly the diagnostic gap that made investigating today's 1h
        test survey require raw journalctl digging instead of being
        obvious from the final error alone.

        PART 5: also persists a full per-attempt quality-evidence record
        (StateManager.record_ppp_ar_attempt()) regardless of outcome -
        product_tier, processed-window-vs-obs-span coverage, AMB
        resolvable-satellite/fixing counts, and the frequency combination
        Part 1 chose - covering FAILED/SKIPPED attempts too, not just
        accepted ones, since current_position is only ever updated on
        success and a run that never got applied would otherwise leave no
        quality evidence behind at all (exactly the gap Pesho's "we need
        it most for attempts that FAIL" requirement calls out).

        Args:
            slot_label: "0h", "4h", ... or "final" - identifies which
                attempt this is.
            result: "SUCCESS" | "SKIPPED" | "FAILED".
            reason: short, human-readable reason (e.g. "pdp3 not found",
                "fix rate below threshold", "applied successfully").
            ppp_ar_result: the dict from _run_ppp_ar(), if one was
                obtained (None if the run never got that far, e.g. pdp3
                not found) - used to pull obs_duration_minutes/
                wl_fix_rate/nl_fix_rate/sig0 for the summary line.
        """
        if ppp_ar_result is not None:
            obs_duration = ppp_ar_result.get('obs_duration_minutes')
            obs_duration_str = f"{obs_duration:.1f}min" if obs_duration is not None else "unknown"
            wl_fix = ppp_ar_result.get('wl_fix_rate')
            nl_fix = ppp_ar_result.get('nl_fix_rate')
            sig0 = ppp_ar_result.get('sig0')
        else:
            obs_duration_str = "unknown"
            wl_fix = None
            nl_fix = None
            sig0 = None

        summary = (
            f"PPP-AR ATTEMPT slot={slot_label} result={result} reason={reason} "
            f"obs_duration={obs_duration_str} "
            f"wl_fix={wl_fix if wl_fix is not None else 'n/a'} "
            f"nl_fix={nl_fix if nl_fix is not None else 'n/a'} "
            f"sig0={sig0 if sig0 is not None else 'n/a'}"
        )

        if result == "SUCCESS":
            logger.info(summary)
        elif result == "SKIPPED":
            logger.info(summary)
        else:
            logger.warning(summary)

        # Kept for _finalize_survey()'s "No final position computed" path
        # to surface the actual cause instead of a generic message - see
        # that method.
        self._last_ppp_ar_attempt_summary = summary

        try:
            self.state.record_ppp_ar_attempt(
                self._build_ppp_ar_attempt_record(slot_label, result, reason, ppp_ar_result,
                                                  failure_info=failure_info)
            )
        except Exception as e:
            logger.error(f"_log_ppp_ar_attempt: failed to persist attempt record: {e}", exc_info=True)

        # A failed/skipped attempt produced no coordinate: surface the reason
        # in last_failure_reason (the UI otherwise shows "unknown error").
        if result in ("FAILED", "SKIPPED"):
            try:
                self.state.record_update_failure(f"PPP-AR slot={slot_label}: {reason}")
            except Exception as e:
                logger.error(f"_log_ppp_ar_attempt: failed to record failure reason: {e}", exc_info=True)

    def _build_ppp_ar_attempt_record(self, slot_label: str, result: str, reason: str,
                                      ppp_ar_result: Optional[Dict],
                                      failure_info: Optional[Dict] = None) -> Dict:
        """
        Build the Part 5 per-attempt quality-evidence dict persisted by
        StateManager.record_ppp_ar_attempt(). Separated from
        _log_ppp_ar_attempt() so its own, fairly dense field-mapping logic
        doesn't crowd that method's primary (logging) responsibility.

        Every field here defaults to None (never a fabricated zero/empty
        value) - see pride_pppar_processor.py's parse_cst_file()/
        parse_amb_file_header() docstrings for why 0 would be
        indistinguishable from a genuine "zero ambiguities fixed" result.
        """
        now_iso = datetime.utcnow().isoformat()
        record = {
            'slot_label': slot_label,
            'timestamp': now_iso,
            'result': result,
            'reason': reason,
            'product_tier': None,
            'processed_window': None,
            'amb_fixing': None,
            'amb_resolvable': None,
            'frequency_selection': None,
            'wl_fix_rate': None,
            'nl_fix_rate': None,
            'sig0': None,
            'obs_duration_minutes': None,
            'fix_rate_mismatch': None,
            'band_calibration': None,
            'failure_stage': None,
            'error_class': failure_info['error_class'] if failure_info else None,
        }
        if ppp_ar_result is None:
            # The run produced no result: take what _run_ppp_ar() learned
            # before it failed (frequency combination, obs duration, stage).
            ctx = getattr(self, '_last_ppp_ar_run_context', None) or {}
            record['frequency_selection'] = ctx.get('frequency_selection')
            record['obs_duration_minutes'] = ctx.get('obs_duration_minutes')
            record['failure_stage'] = ctx.get('stage')
            return record

        obs_duration_minutes = ppp_ar_result.get('obs_duration_minutes')
        processed_window = ppp_ar_result.get('processed_window')
        coverage = None
        if processed_window is not None:
            coverage = check_processed_window_coverage(
                processed_window.get('processed_minutes'), obs_duration_minutes)
            if coverage is not None and coverage['warning']:
                logger.warning(
                    f"PPP-AR ATTEMPT slot={slot_label}: pdp3 processed only "
                    f"{coverage['processed_minutes']:.1f}min of the "
                    f"{coverage['obs_duration_minutes']:.1f}min obs file offered to it "
                    f"({coverage['ratio']*100:.0f}%, below the "
                    f"{self.PPP_AR_PROCESSED_WINDOW_WARN_PERCENT:.0f}% threshold) - "
                    f"a silent window truncation upstream of pdp3 itself."
                )

        record.update({
            'product_tier': ppp_ar_result.get('product_tier'),
            'processed_window': {
                'first_epoch': processed_window['first_epoch'].isoformat(),
                'last_epoch': processed_window['last_epoch'].isoformat(),
                'processed_minutes': processed_window['processed_minutes'],
                'obs_duration_minutes': obs_duration_minutes,
                'coverage_ratio': coverage['ratio'] if coverage else None,
                'coverage_warning': coverage['warning'] if coverage else None,
            } if processed_window is not None else None,
            'amb_fixing': ppp_ar_result.get('amb_fixing'),  # {'per_constellation', 'combined', 'ar_result'} | None
            'amb_resolvable': ppp_ar_result.get('amb_resolvable'),  # {'amb_fixing', 'resolvable_sat_count', 'resolvable_satellites'} | None
            'frequency_selection': ppp_ar_result.get('frequency_selection'),  # select_frequency_combination()'s own dict | None
            'wl_fix_rate': ppp_ar_result.get('wl_fix_rate'),
            'nl_fix_rate': ppp_ar_result.get('nl_fix_rate'),
            'sig0': ppp_ar_result.get('sig0'),
            'obs_duration_minutes': obs_duration_minutes,
            # Part 9: set by _ppp_ar_fix_rate_ok() (mutates ppp_ar_result
            # in place) when the stdout fix rate disagrees with cst_*'s
            # own T/W/N-computed percentages by more than 0.1% - a parser
            # bug signal, never itself a reason this attempt was
            # accepted/rejected. None when the two agree (or cst_* data
            # wasn't available to compare against at all).
            'fix_rate_mismatch': ppp_ar_result.get('fix_rate_mismatch'),
            # Part 6b (item 3): per-band calibration status for the
            # bands this attempt's frequency_selection actually used -
            # see classify_band_calibration()'s own docstring for the
            # three possible values per band.
            'band_calibration': ppp_ar_result.get('band_calibration'),
        })
        return record

    # Part 5: if pdp3 actually processed less than this fraction of the
    # obs file's own full span, warn - see pride_pppar_processor.py's
    # PROCESSED_WINDOW_WARN_RATIO (the actual threshold value; this is
    # only its percent-form for the warning log message above).
    PPP_AR_PROCESSED_WINDOW_WARN_PERCENT = 50.0


    # Final-result retry (PPP-AR mode): the final coordinates are retried
    # until they succeed (CLAUDE.md: "infinite retry until success"), with
    # visible indicators (state: final_attempts / final_last_reason /
    # final_next_retry_at, plus last_heartbeat_at). Short delay for the first
    # attempts (a missing product or a transient network problem usually
    # clears quickly), then hourly - e.g. rapid precise products for the last
    # hours of a survey are only published many hours later.
    FINAL_RETRY_FAST_ATTEMPTS = 5
    FINAL_RETRY_FAST_SECONDS = 600
    FINAL_RETRY_SLOW_SECONDS = 3600
    HEARTBEAT_INTERVAL_SECONDS = 60
    # Before each real attempt the products server is listed (cheap); while the
    # required daily products are not published the loop only polls every
    # FINAL_PRODUCT_POLL_SECONDS. A real pdp3 attempt is still made at least
    # every FINAL_BLIND_ATTEMPT_SECONDS regardless of the listing, so a wrong
    # file-name assumption or a server layout change can never block the final
    # result forever.
    FINAL_PRODUCT_POLL_SECONDS = 600
    FINAL_BLIND_ATTEMPT_SECONDS = 6 * 3600

    def _final_products_status(self, window_start: datetime, window_end: datetime) -> Dict:
        """check_products_available() for the window, never raising (unknown -> None)."""
        try:
            return check_products_available(window_start, window_end)
        except Exception as e:
            return {'available': None, 'missing': [], 'error': f"{type(e).__name__}: {e}"}

    def _final_retry_delay_seconds(self, attempt: int) -> int:
        """Delay before the next final attempt after `attempt` failed ones."""
        return (self.FINAL_RETRY_FAST_SECONDS if attempt <= self.FINAL_RETRY_FAST_ATTEMPTS
                else self.FINAL_RETRY_SLOW_SECONDS)

    def _wait_while_running(self, seconds: float) -> None:
        """Sleep up to `seconds`, in short steps, returning early as soon as the
        survey is stopped/paused/reset; keeps the heartbeat fresh meanwhile."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if not self._running or self.state.survey_state not in (SurveyState.RUNNING, SurveyState.FINALIZING):
                return
            self.state.record_heartbeat(self.HEARTBEAT_INTERVAL_SECONDS)
            time.sleep(min(5.0, max(0.0, deadline - time.monotonic())))

    def _attempt_final_ppp_ar(self, window_end: datetime) -> bool:
        """
        One attempt at the FINAL PRIDE-PPPAR position over the frozen window
        [survey start, window_end]. Returns True only if the position was
        computed, cleared the fix-rate gate and was applied.
        """
        try:
            ppp_ar_result = self._run_ppp_ar(slot_label="final", window_end=window_end)
            if ppp_ar_result is None:
                logger.warning("PPP-AR final run produced no result")
                info = self._ppp_ar_failure_info()
                self._log_ppp_ar_attempt("final", "FAILED", f"{info['reason']} [{info['error_class']}]",
                                         failure_info=info)
                return False
            if not self._ppp_ar_fix_rate_ok(ppp_ar_result):
                logger.warning(
                    f"PPP-AR final run: fix rate below threshold "
                    f"(WL={ppp_ar_result.get('wl_fix_rate')}%, need >= "
                    f"{self.PPP_AR_MIN_WL_FIX_RATE_PERCENT}%; "
                    f"NL={ppp_ar_result.get('nl_fix_rate')}%, need >= "
                    f"{self.PPP_AR_MIN_NL_FIX_RATE_PERCENT}%)"
                )
                info = self._ppp_ar_failure_info(STAGE_FIX_RATE_BELOW_THRESHOLD)
                self._log_ppp_ar_attempt(
                    "final", "SKIPPED",
                    f"{info['reason']} (WL={ppp_ar_result.get('wl_fix_rate')}%, "
                    f"NL={ppp_ar_result.get('nl_fix_rate')}%) [{info['error_class']}]",
                    ppp_ar_result, failure_info=info)
                return False
            logger.info(
                f"✓ PPP-AR final run: fix rate cleared threshold "
                f"(WL={ppp_ar_result['wl_fix_rate']}%, "
                f"NL={ppp_ar_result['nl_fix_rate']}%) - applying final position"
            )
            final_applied = self._apply_geodetic_position(
                lat=ppp_ar_result['lat'],
                lon=ppp_ar_result['lon'],
                height=ppp_ar_result['height'],
                obs_file=ppp_ar_result['obs_file'],
                is_final=True,
                ppp_backend='pride-pppar',
                position_std={
                    # No direct N/E/U std available from PRIDE-PPPAR's ECEF
                    # sigmas.
                    'std_lat': 0.0,
                    'std_lon': 0.0,
                    'std_height': 0.0,
                    'std_h_meters': 0.0,
                },
                num_epochs=int(ppp_ar_result.get('nobs', 0)),
                quality_metrics={
                    'is_final': True,
                    'ppp_tier': ppp_ar_result.get('product_tier'),
                    'ppp_ar_sig0': ppp_ar_result.get('sig0'),
                    'ppp_ar_wl_fix_rate': ppp_ar_result.get('wl_fix_rate'),
                    'ppp_ar_nl_fix_rate': ppp_ar_result.get('nl_fix_rate'),
                },
                extra_position_fields=self._ppp_ar_extra_position_fields(ppp_ar_result),
                ppp_ar_dir=ppp_ar_result.get('ppp_ar_dir'),
            )
            if final_applied:
                self._log_ppp_ar_attempt("final", "SUCCESS", "applied successfully", ppp_ar_result)
                return True
            info = self._ppp_ar_failure_info(STAGE_APPLY_FAILED)
            self._log_ppp_ar_attempt("final", "FAILED", f"{info['reason']} [{info['error_class']}]",
                                     ppp_ar_result, failure_info=info)
            return False
        except Exception as ppp_ar_err:
            logger.error(f"PPP-AR final step failed: {ppp_ar_err}", exc_info=True)
            self._log_ppp_ar_attempt("final", "FAILED", f"unhandled exception: {ppp_ar_err}")
            return False

    def _finalize_survey(self):
        """
        Finalize survey at completion:
        1. Process all accumulated data with RINEX
        2. Generate final position estimate
        3. Update configuration with best estimate
        4. Mark survey as completed
        5. Restart main service to apply new coordinates
        6. Stop file logging to prevent disk space issues

        ARCHITECTURE: PRIDE-PPPAR-only. _run_ppp_ar() runs, and only if its
        wide-lane/narrow-lane fix rates clear
        PPP_AR_MIN_WL_FIX_RATE_PERCENT/PPP_AR_MIN_NL_FIX_RATE_PERCENT is its
        result applied via _apply_geodetic_position(). If PRIDE-PPPAR fails
        or the fix rate doesn't clear the threshold, the final update does
        not happen this run; the caller retries (no fallback backend).
        """
        try:
            logger.info("=" * 60)
            logger.info("🎯 FINALIZING SURVEY - Processing complete 24h dataset...")
            logger.info("=" * 60)

            # Snapshot any previously computed position so we can still complete even if final update fails
            before_status = self.state.get_status()
            before_pos = before_status.get('current_position')

            # PRIDE-PPPAR is the only pipeline.
            # FROZEN final window: [survey start, start + target]. Derived from
            # the persisted start time and target, so a retry hours later (or
            # after a restart) processes exactly the same window.
            start_raw = before_status.get('start_time')
            window_end = (datetime.fromisoformat(start_raw) if start_raw else datetime.utcnow()) \
                + timedelta(hours=self.target_hours)
            logger.info(f"Final window frozen at {window_end.isoformat()} (UTC)")
            # The survey duration is over: data collection STOPS now (the
            # File service is survey-only) and the survey enters the
            # 'finalizing' state - it is not 'running' any more, but it is
            # resumed automatically after a restart until its final result
            # has been computed and applied.
            self.state.begin_finalizing()
            if self.auto_mode:
                self._stop_file_logging(reason="data_collection_complete")
            attempt = 0
            final_applied = False
            window_start = (datetime.fromisoformat(start_raw) if start_raw
                            else window_end - timedelta(hours=self.target_hours))
            last_real_attempt = time.monotonic()
            # INFINITE RETRY until the final position is accepted (policy);
            # leaves the loop early only when the survey is stopped/paused/
            # reset or the service is shutting down (state stays 'running'
            # so a restart resumes the retry). A real pdp3 attempt is made only
            # when the precise products of every UTC day of the window are
            # published (cheap server listing) - or, as a safety net, at least
            # every FINAL_BLIND_ATTEMPT_SECONDS.
            while self._running and self.state.survey_state in (SurveyState.RUNNING, SurveyState.FINALIZING):
                self.state.record_heartbeat(self.HEARTBEAT_INTERVAL_SECONDS)
                products = self._final_products_status(window_start, window_end)
                blind_due = (time.monotonic() - last_real_attempt) >= self.FINAL_BLIND_ATTEMPT_SECONDS
                if products.get('available') is False and not blind_due:
                    missing = ", ".join(products.get('missing') or []) or "unknown"
                    reason = f"waiting for precise products to be published: {missing}"
                    poll = self.FINAL_PRODUCT_POLL_SECONDS
                    next_check = (datetime.utcnow() + timedelta(seconds=poll)).isoformat()
                    self.state.record_final_attempt(attempt, reason, next_check)
                    logger.info(f"FINAL result waiting: {reason} (checking again in {poll // 60} min)")
                    self._wait_while_running(poll)
                    continue
                attempt += 1
                last_real_attempt = time.monotonic()
                final_applied = self._attempt_final_ppp_ar(window_end)
                if final_applied:
                    break
                delay = self._final_retry_delay_seconds(attempt)
                next_retry = (datetime.utcnow() + timedelta(seconds=delay)).isoformat()
                reason = self._last_ppp_ar_attempt_summary or "final attempt failed"
                self.state.record_final_attempt(attempt, reason, next_retry)
                logger.warning(f"FINAL attempt {attempt} failed - retrying in {delay // 60} min "
                               f"(infinite retry until success): {reason}")
                self._wait_while_running(delay)
            if not final_applied:
                logger.info("Final retry loop left before success (survey stopped or service "
                            "shutting down); the survey stays resumable")
                return
            self.state.clear_final_attempts()

            # Get current state
            status = self.state.get_status()
            pos = status.get('current_position') or before_pos

            if pos:
                std = status.get('position_std', {})

                self.state.complete_survey(pos)

                logger.info("=" * 60)
                logger.info("✓ SURVEY COMPLETED SUCCESSFULLY")
                # pos['lat']/lon are the BGS2005-transformed broadcast
                # coordinate (see _apply_geodetic_position()), and
                # pos['height'] is ALWAYS ellipsoidal (GRS80) - see Step 8's
                # comment for why RTCM broadcast height must never be
                # geoid-corrected - never the raw ITRF2020 PPP estimate.
                logger.info(f"Final Position (BGS2005, {pos.get('broadcast_height_type', 'ellipsoidal')} height): "
                            f"{pos['lat']:.8f}°, {pos['lon']:.8f}°, {pos['height']:.3f}m")
                logger.info(f"Horizontal Accuracy: {std.get('std_h_meters', 0)*1000:.1f}mm")
                logger.info(f"Vertical Accuracy: {std.get('std_height', 0)*1000:.1f}mm")
                logger.info(f"Total Epochs: {status.get('num_epochs', 0)}")
                logger.info("=" * 60)

                # CRITICAL: Apply coordinates to RTKBase configuration FIRST
                # (pos already holds the correct broadcast coordinate/height
                # type for this survey - see comment above)
                try:
                    if self.state.get_apply_mode() == 'propose':
                        logger.info("Propose mode: the final position is stored as a proposal; "
                                    "settings.conf is NOT changed")
                        update_applied = False
                    else:
                        logger.info(f"✓ Applying coordinates to RTKBase (BGS2005, "
                                    f"{pos.get('broadcast_height_type', 'ellipsoidal')} height): "
                                    f"{pos['lat']:.8f} {pos['lon']:.8f} {pos['height']:.3f}")
                        update_applied = self.rtkbase.update_position(pos['lat'], pos['lon'], pos['height'])
                    if self.state.get_apply_mode() == 'propose':
                        pass
                    elif update_applied:
                        logger.info("✓ RTKBase configuration updated successfully")
                        # Persist that coordinates were applied
                        self.state.mark_applied({
                            'lat': pos['lat'],
                            'lon': pos['lon'],
                            'height': pos['height'],
                            'broadcast_height_type': pos.get('broadcast_height_type', 'ellipsoidal'),
                            'height_ellipsoidal': pos.get('height_ellipsoidal'),
                            'height_msl': pos.get('height_msl'),
                            'coordinate_system': pos.get('coordinate_system', 'BGS2005'),
                        })
                        
                        # CRITICAL: Wait for filesystem to stabilize (settings.conf is flushed)
                        logger.info("Waiting 2 seconds for settings.conf to stabilize...")
                        time.sleep(2)
                        
                        # NOW restart services - settings.conf is guaranteed to be on disk
                        try:
                            _announce_planned_disconnect(self.rtkbase, "auto_survey")
                            restart_result = self.restart_rtkbase_services()
                            if not restart_result['success']:
                                logger.warning("⚠ Service restart failed - coordinates may not be applied until manual restart")
                        except Exception as e:
                            logger.error(f"✗ Service restart error: {e}")
                            self._services_restarted = False
                    else:
                        logger.error("✗ Failed to update RTKBase configuration")
                except Exception as e:
                    logger.error(f"✗ Failed to apply coordinates: {e}")
                
                # CRITICAL: Stop file logging to prevent disk space issues
                if self.auto_mode:
                    logger.info("Stopping file logging to prevent disk filling...")
                    self._stop_file_logging(reason="survey_completed")
            else:
                # Include the LAST PPP-AR-specific failure reason (from
                # _log_ppp_ar_attempt()'s ATTEMPT summary lines) when
                # available, instead of a generic, context-free message -
                # this is exactly the diagnostic gap that made
                # investigating a real failed PPP-AR test survey require
                # raw journalctl digging instead of being obvious from
                # the final error alone. Falls back to a generic message
                # when no PPP-AR attempt was ever logged this instance's
                # lifetime.
                if self._last_ppp_ar_attempt_summary:
                    fail_reason = f"No final position computed - last {self._last_ppp_ar_attempt_summary}"
                else:
                    fail_reason = "No final position computed"
                logger.error(f"No position available for finalization ({fail_reason})")
                self._fail(fail_reason)

        except Exception as e:
            logger.error(f"Finalization failed: {e}", exc_info=True)
            self._services_restarted = False
            self._fail(str(e))
        
        finally:
            self._running = False
    
    def get_status(self) -> Dict:
        """
        Get current survey status
        
        Returns:
            Dict with survey state, progress, current position, etc.
        """
        # The runner service owns and writes the state; the web application's
        # controller must see its latest version from disk on every call.
        if not self.is_runner:
            self.state.reload()
        status = self.state.get_status()

        # Auto-apply coordinates if survey is completed but not yet applied.
        # pos['lat']/lon are the BGS2005-transformed broadcast coordinate,
        # and pos['height'] is ALWAYS ellipsoidal (GRS80) - see
        # _apply_geodetic_position() - not raw ITRF2020 either way, no
        # re-transformation needed here. Only the runner applies (the web
        # application would otherwise race the runner on the same state).
        try:
            if (self.is_runner and status.get('survey_state') == SurveyState.COMPLETED.value
                    and not status.get('applied')
                    and self.state.get_apply_mode() != 'propose'):
                pos = status.get('final_position') or status.get('current_position')
                if pos:
                    logger.info("Auto-applying completed survey coordinates to RTKBase (previously unapplied)")
                    if self.rtkbase.update_position(pos['lat'], pos['lon'], pos['height']):
                        logger.info("✓ Auto-apply succeeded; marking state as applied")
                        self.state.mark_applied(pos)
                        # Optionally restart services to ensure live config reload
                        try:
                            _announce_planned_disconnect(self.rtkbase, "auto_survey")
                            self.restart_rtkbase_services()
                        except Exception as restart_err:
                            logger.warning(f"Service restart after auto-apply failed: {restart_err}")
                    else:
                        logger.error("✗ Auto-apply failed (update_position returned False)")
        except Exception as auto_apply_err:
            logger.error(f"Auto-apply check failed: {auto_apply_err}")

        # In the runner the survey thread is authoritative; in the web
        # application (no thread of its own) the persisted state is.
        status['is_running'] = (self._running if self.is_runner
                                else status.get('survey_state') in (SurveyState.RUNNING.value,
                                                                    SurveyState.FINALIZING.value))

        # Part 6a: current antenna calibration status, for the Autosurvey
        # page's uncalibrated-antenna note - resolved fresh on every
        # status call (cheap: one ANTEX file read) rather than cached,
        # so a mid-survey antenna_info/ANTEX change is reflected
        # immediately rather than only at the next update.
        try:
            antenna = self._resolve_antenna_calibration()
            status['antenna_type'] = antenna['antenna_type']
            status['antenna_calibrated'] = antenna['antenna_calibrated']
        except Exception as e:
            logger.warning(f"get_status: failed to resolve antenna calibration: {e}")

        return status

    def _load_geoid_model(self):
        """Load geoid model if configured"""
        try:
            if not self.geoid_config_path.exists():
                logger.info("No geoid config found; using ellipsoidal heights")
                return
            import json
            with open(self.geoid_config_path, 'r') as f:
                data = json.load(f)
            geoid_path = data.get('ggf_path')
            if geoid_path and Path(geoid_path).exists():
                if self.geoid.load_model(geoid_path):
                    logger.info(f"Geoid model loaded from {geoid_path}")
                else:
                    logger.warning(f"Failed to load geoid model at {geoid_path}")
            else:
                logger.info("Geoid path not set or file missing; using ellipsoidal heights")
        except Exception as e:
            logger.error(f"Failed to load geoid config: {e}")

    def set_geoid_model(self, ggf_path: Path) -> bool:
        """Persist and load selected geoid model"""
        try:
            if not ggf_path.exists():
                logger.error(f"Geoid file not found: {ggf_path}")
                return False
            import json
            self.geoid_config_path.parent.mkdir(parents=True, exist_ok=True)
            with open(self.geoid_config_path, 'w') as f:
                json.dump({'ggf_path': str(ggf_path)}, f, indent=2)
            if self.geoid.load_model(str(ggf_path)):
                logger.info(f"Geoid model set to {ggf_path}")
                return True
            logger.error(f"Failed to load geoid model: {self.geoid.last_error}")
            return False
        except Exception as e:
            logger.error(f"Failed to set geoid model: {e}")
            return False
    
    def _fail(self, reason: str):
        """Mark survey as failed and ensure file logging is stopped (prevents orphaned File Service / disk fill)."""
        try:
            self._stop_file_logging(reason="survey_failed")
        except Exception as e:
            logger.error(f"Failed to stop file logging during failure handling: {e}")
        self.state.fail_survey(reason)
        log_event("auto_survey", "failed", {"reason": reason})

    def reset_survey(self) -> bool:
        """
        Fully reset survey to clean idle state, clearing all historical data
        (position, epochs, errors). Different from stop_survey(), which
        pauses but preserves last-known results.
        """
        if self._running:
            self.stop_survey()
        result = self.state.reset_survey()
        logger.info("Survey manually reset to idle state")
        log_event("auto_survey", "reset", {})
        return result

    def recover_survey(self) -> bool:
        """
        Attempt to recover survey after restart

        Returns:
            True if recovery successful
        """
        if not self.state.can_recover():
            # A survey still marked 'running' that can no longer be recovered
            # (older than its target duration plus the recovery grace) must
            # not look alive forever: fail it with an explicit reason. A
            # 'paused' survey was stopped by the user and is left alone.
            self.recovery_pending = False
            if self.is_runner and self.state.survey_state == SurveyState.RUNNING:
                self._fail("Survey was still marked running but is older than its target "
                           "duration plus the recovery grace period; it cannot be resumed")
            logger.info("No recoverable survey found")
            return False

        saved_input_type = self.rtkbase.config.get('main', 'receiver_format', fallback='').strip("'")
        try:
            main_service_active = subprocess.run(
                ['systemctl', 'is-active', 'str2str_tcp.service'],
                capture_output=True,
                text=True
            ).returncode == 0
        except Exception as e:
            logger.warning(f"Failed to check main service status: {e}")
            main_service_active = False

        is_receiver_ready = (
            main_service_active
            and saved_input_type in
            ["rtcm2","rtcm3","nov","oem3","ubx","ss2","hemis","stq","javad","nvs","binex","rt17","sbf","unicore"]
        )
        if not is_receiver_ready:
            logger.warning("Cannot recover survey: GNSS receiver not ready (service inactive or invalid format)")
            if self.is_runner:
                # Transient (boot / OTA / restart ordering): keep the survey
                # 'running' and let the runner retry; failing here would
                # abandon a healthy multi-hour survey.
                self.recovery_pending = True
                return False
            self._fail("GNSS receiver not ready (service inactive or invalid format). Configure the receiver in Main Service settings before starting Auto Survey-In.")
            return False

        logger.info("Recovering previous survey session...")

        # Ensure controller uses the persisted target_hours (so loop
        # completion matches what was actually started, not this instance's
        # just-initialized default)
        try:
            status = self.state.get_status()
            target_hours = status.get('target_hours')
            if isinstance(target_hours, (int, float)) and target_hours > 0:
                self.target_hours = int(target_hours)
        except Exception as e:
            logger.warning(f"Failed to read target_hours from state: {e}")
        
        # Resume from saved state
        if self.state.survey_state == SurveyState.PAUSED:
            self.state.resume_survey()
        
        # SURVEY-ONLY File service policy: the survey owns str2str_file for its
        # whole duration, so a resumed survey (after a crash, reboot or
        # service restart) must make sure it is running again.
        # (Not for a FINALIZING survey: its data collection is over, the File
        # service must stay off while it waits for the precise products.)
        if self.state.survey_state == SurveyState.FINALIZING:
            logger.info("Recovered survey is finalizing: File service stays off")
        elif not self._ensure_file_logging():
            logger.warning("Recovered survey: File service could not be started; "
                           "the file-logging health check will keep retrying")

        # Restart survey thread
        self._running = True
        self._thread = threading.Thread(target=self._survey_loop, daemon=True)
        self._thread.start()

        self.recovery_pending = False
        self.state.record_resume()
        resume_count = self.state.get_status().get('resume_count')
        logger.info(f"Survey resumed after interruption (resume #{resume_count})")
        log_event("auto_survey", "recovered", {"resumed_after_interruption": True,
                                                "resume_count": resume_count})
        return True
