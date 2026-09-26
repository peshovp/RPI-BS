"""
Auto Survey-In Controller
=========================

Main controller for 24-hour automatic survey-in process.

Orchestrates:
- RTKBase configuration auto-discovery
- GNSS data logging (enables str2str_file if needed)
- RINEX conversion from raw logs
- PPP-static positioning (rnx2rtkp -p 8) using CDDIS precise orbit/clock
  products, with outlier rejection
- Geoid correction
- ITRF2020 -> BGS2005 transformation (Инструкция № РД-02-20-25, Чл.22,
  ал.1 - see bgs2005_transformer.py) before RTCM broadcast
- RTKBase configuration updates
- State persistence

PHASE 2D: full replacement of SPPProcessor with PPPProcessor - no SPP
fallback. A failed precise-product fetch or PPP processing run surfaces as
a failed update (via StateManager.record_update_failure()), exactly like
any other failure mode already handled here; it does not silently degrade
to SPP. This matches Pesho's explicit "no fallback, no silent start"
decision, already established for ppp_downloader.py's own error handling.
"""

import logging
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
from .rinex_converter import RINEXConverter
from .ppp_processor import PPPProcessor
from .ppp_downloader import PPPDownloader, PPPDownloaderError
from .pride_pppar_processor import PridePpparProcessor, Pdp3NotFoundError
from .bgs2005_transformer import GeodeticPoint, itrf2020_to_bgs2005, extract_observation_epoch, extract_observation_duration_minutes
from .position_estimator import PositionEstimator
from .geoid_corrector import GeoidCorrector
from .config_manager import ConfigManager
from .state_manager import StateManager, SurveyState

try:
    from audit_logger import log_event
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
    - Processes with PPP-static positioning (rnx2rtkp -p 8, CDDIS precise
      orbit/clock products)
    - Transforms ITRF2020 -> BGS2005 before broadcast (Инструкция №
      РД-02-20-25, Чл.22, ал.1)
    - Updates RTKBase config hourly
    """
    
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
        self.spp = PPPProcessor(rtkbase_root=self.rtkbase.rtkbase_root)
        self.estimator = PositionEstimator(outlier_threshold=3.5, min_epochs=50)
        self.geoid = GeoidCorrector()
        self.config = ConfigManager(settings_file)
        self.state = StateManager(state_file)

        # Precise-product downloader (CDDIS SP3/CLK, Phase 2b) - one
        # instance reused across the whole survey so the authenticated
        # session (Earthdata Login cookies) persists across interim
        # updates instead of re-authenticating every 15 minutes/hour.
        self.ppp_products_dir = self.rtkbase.rtkbase_root / "geomaxima_ppp" / "products"
        self.ppp_products_dir.mkdir(parents=True, exist_ok=True)
        self.ppp_downloader = PPPDownloader(products_dir=self.ppp_products_dir)

        # Geoid config (upload directory + persisted config)
        self.geoid_dir = self.rtkbase.rtkbase_root / "geomaxima_geoid"
        self.geoid_dir.mkdir(parents=True, exist_ok=True)
        self.geoid_config_path = self.geoid_dir / "geoid_config.json"
        self._load_geoid_model()
        
        # Survey parameters
        self.target_hours = 24
        self.ppp_tier = 'rapid'
        self.ppp_ar_enabled = False
        # Last "PPP-AR ATTEMPT ..." summary line logged by
        # _log_ppp_ar_attempt() (interim or finalize) - used by
        # _finalize_survey()'s "No final position computed" error path to
        # surface the actual last PPP-AR failure reason instead of a
        # generic, context-free message. None until the first PPP-AR
        # attempt of this instance's lifetime.
        self._last_ppp_ar_attempt_summary = None

        # Hard timeout: fail survey if no successful coordinate update happens for X minutes.
        # Configurable via env var AUTOSURVEY_UPDATE_TIMEOUT_MINUTES.
        try:
            self.update_timeout_minutes = int(os.getenv('AUTOSURVEY_UPDATE_TIMEOUT_MINUTES', '60'))
        except Exception:
            self.update_timeout_minutes = 60
        if self.update_timeout_minutes < 1:
            self.update_timeout_minutes = 60
        
        # Progressive update schedule:
        # - First 6 hours: every 15 minutes (0.25 hours)
        # - 6-24 hours: every 1 hour
        # - At 24 hours: final update
        self.update_schedule = {
            'initial_interval': 0.25,  # 15 minutes for first 6 hours
            'initial_period': 6,       # Use 15-min interval for 6 hours
            'later_interval': 1        # 1 hour after 6 hours
        }
        
        # Working directory for temp files
        self.work_dir = self.rtkbase.rtkbase_root / "geomaxima_survey"
        self.work_dir.mkdir(parents=True, exist_ok=True)
        
        # Control flags
        self._running = False
        self._thread: Optional[threading.Thread] = None
        self._services_restarted = False  # Track if services were restarted after completion
        
        logger.info(f"Survey controller initialized (auto_mode={auto_mode})")
        logger.info(f"Work dir: {self.work_dir}")
        logger.info(f"Hard update timeout: {self.update_timeout_minutes} minutes")
    
    def _ensure_file_logging(self) -> bool:
        """
        Ensure RTKBase file logging service is enabled
        
        Returns:
            True if logging is active or successfully started
        """
        try:
            # Check if str2str_file service is running
            result = subprocess.run(
                ['systemctl', 'is-active', 'str2str_file.service'],
                capture_output=True,
                text=True
            )

            was_already_active = (result.returncode == 0)
            if was_already_active:
                logger.info("✓ File logging service already running (not owned by this survey)")
                self.state.set_file_service_owned(False)
                return True

            # Try to start the service
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
    
    def _stop_file_logging(self, reason: str = "unknown") -> bool:
        """
        Stop RTKBase file logging service to prevent disk space issues

        Args:
            reason: Short label identifying which code path triggered the stop
                (e.g. "manual_stop", "survey_completed", "survey_failed"),
                logged for future diagnosis.

        Returns:
            True if logging stopped successfully
        """
        if not self.state.get_file_service_owned():
            logger.info(f"Skipping file logging stop (reason: {reason}) - service was not started by this survey")
            return True

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
                return True
            else:
                logger.warning(f"Could not stop file logging: {result.stderr}")
                return False
                
        except Exception as e:
            logger.error(f"Failed to stop file logging: {e}")
            return False
    
    def start_survey(self, target_hours: int = 24, ppp_tier: str = 'rapid',
                      ppp_ar_enabled: bool = False) -> bool:
        """
        Start new survey session

        Args:
            target_hours: Survey duration in hours (default: 24)
            ppp_tier: CDDIS precise-product tier for PPP-static processing
                ("ultra-rapid" | "rapid" | "final"). "rapid" is the default:
                usually available within the survey's own timeframe (up to
                ~41h latency) without the accuracy tradeoffs of
                ultra-rapid's predicted-orbit half.
            ppp_ar_enabled: Opt-in PRIDE-PPPAR final ambiguity-resolution
                step (default False - not default-on). If True, runs
                pdp3 ONCE at survey finalization only (never per interim
                update, to stay within this station's RAM budget) via
                _run_ppp_ar(); its result replaces the rnx2rtkp broadcast
                position only if its wide-lane/narrow-lane fix rates clear
                PPP_AR_MIN_FIX_RATE_PERCENT, otherwise the existing
                rnx2rtkp result is used unchanged (never a hard failure).

        Returns:
            True if started successfully
        """
        if ppp_tier not in ('ultra-rapid', 'rapid', 'final'):
            logger.error(f"Invalid ppp_tier: {ppp_tier!r}")
            return False

        if not isinstance(ppp_ar_enabled, bool):
            logger.error(f"Invalid ppp_ar_enabled (must be bool): {ppp_ar_enabled!r}")
            return False

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
        self.ppp_tier = ppp_tier
        self.ppp_ar_enabled = ppp_ar_enabled
        if not self.state.start_survey(target_hours, ppp_tier=ppp_tier,
                                        ppp_ar_enabled=ppp_ar_enabled):
            logger.error("Failed to initialize survey state")
            return False
        
        # Start survey thread
        self._running = True
        self._thread = threading.Thread(target=self._survey_loop, daemon=True)
        self._thread.start()
        
        logger.info(f"✓ Started {target_hours}-hour auto survey")
        log_event("auto_survey", "start", {"target_hours": target_hours})
        return True
    
    def stop_survey(self) -> bool:
        """
        Stop running survey and disable file logging
        
        Returns:
            True if stopped successfully
        """
        if not self._running:
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
    
    def _compute_ppp_ar_slots(self) -> list:
        """
        Fixed PPP-AR interim slot schedule: 0h, 4h, 8h, ... up to but
        EXCLUDING target_hours (the final slot is always handled
        separately by _finalize_survey(), never by this interim
        schedule) - per Pesho's explicit "0h, 4h, 8h... to target_hours =
        final, excluding the final slot" instruction.

        ORDERING GUARANTEE (enforced by _survey_loop()'s caller logic, not
        here): a slot is only ever run/applied if no LATER slot is
        simultaneously due - e.g. after a restart/downtime lets both the
        4h and 8h slots become due in the same tick, only the 8h slot
        actually runs; the 4h slot is marked attempted and skipped
        outright, never run out of order. This is because a later slot
        always has more accumulated data and is therefore always at least
        as accurate, so an older due slot must never be allowed to
        overwrite a newer one's position - neither in the same tick nor
        on a later one.

        Returns:
            Sorted list of slot_hours floats.
        """
        slots = []
        slot = 0.0
        while slot < self.target_hours:
            slots.append(slot)
            slot += self.PPP_AR_SLOT_INTERVAL_HOURS
        return slots

    def _survey_loop(self):
        """
        Main survey loop - runs in background thread

        Two entirely separate update schedules, chosen once per loop by
        self.ppp_ar_enabled (checked once here, not per-tick, since it
        cannot change while a survey is running - see start_survey()):

        - self.ppp_ar_enabled == False (default): the original rnx2rtkp/
          CDDIS progressive schedule - 15min (0-6h) -> 1h (6-24h) ->
          final. Unchanged from before this method was split.
        - self.ppp_ar_enabled == True: PRIDE-PPPAR-ONLY fixed-slot
          schedule - 0h, 4h, 8h, ... (PPP_AR_SLOT_INTERVAL_HOURS) up to
          target_hours, handled by _run_ppp_ar_interim(). rnx2rtkp/CDDIS
          is never invoked in this mode (see _finalize_survey()). A
          failed/skipped slot is simply marked attempted and NOT retried
          before the next fixed slot - no 60s-retry reschedule the way
          the rnx2rtkp path does. ORDERING GUARANTEE: if multiple
          unattempted slots are due at once (e.g. after a restart/
          downtime), only the LATEST (highest) one is actually run and
          broadcast - any earlier due-but-unattempted slots are marked
          attempted and skipped without ever running, since a later slot
          always has more accumulated data and must never be overwritten
          by an older one's result (see _compute_ppp_ar_slots()'s
          docstring).
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

        if self.ppp_ar_enabled:
            ppp_ar_slots = self._compute_ppp_ar_slots()
            logger.info(f"Survey loop started, target: {self.target_hours} hours")
            logger.info(f"PPP-AR enabled: fixed-slot schedule every "
                        f"{self.PPP_AR_SLOT_INTERVAL_HOURS}h ({ppp_ar_slots}), "
                        f"final slot handled separately at {self.target_hours}h. "
                        f"rnx2rtkp/CDDIS is NOT used in this mode.")
        else:
            # Schedule next update using persisted last_update_time (so restarts don't delay updates).
            last_update_raw = status.get('last_update_time')
            if last_update_raw:
                try:
                    last_update_time = datetime.fromisoformat(last_update_raw)
                except Exception:
                    last_update_time = None
            else:
                last_update_time = None

            elapsed_hours_now = (datetime.utcnow() - start_time).total_seconds() / 3600
            initial_interval = self.update_schedule['initial_interval']
            later_interval = self.update_schedule['later_interval']
            interval = initial_interval if elapsed_hours_now < self.update_schedule['initial_period'] else later_interval
            next_update = (last_update_time + timedelta(hours=interval)) if last_update_time else (start_time + timedelta(hours=interval))

            logger.info(f"Survey loop started, target: {self.target_hours} hours")
            logger.info("Progressive updates: 15min (0-6h) → 1h (6-24h) → final (24h)")
            logger.info(f"Using RINEX conversion workflow (RTKBase raw logs → RINEX → PPP-static, tier={self.ppp_tier})")

        try:
            while self._running:
                # Stop doing work if state is not RUNNING (e.g., paused/reset from UI)
                if self.state.survey_state != SurveyState.RUNNING:
                    time.sleep(2)
                    continue

                now = datetime.utcnow()
                elapsed_hours = (now - start_time).total_seconds() / 3600

                # Hard timeout: fail if no successful update for too long.
                # PPP-AR mode uses PPP_AR_UPDATE_TIMEOUT_MINUTES instead of
                # update_timeout_minutes - the latter is calibrated for the
                # rnx2rtkp path's much shorter interval-with-retry
                # schedule and would spuriously trip roughly an hour after
                # every successful 4h PPP-AR slot (see
                # PPP_AR_UPDATE_TIMEOUT_MINUTES's own comment).
                try:
                    st = self.state.get_status()
                    last_success_raw = st.get('last_success_update_time')
                    if last_success_raw:
                        last_success = datetime.fromisoformat(last_success_raw)
                    else:
                        last_success = start_time
                    minutes_since_success = (now - last_success).total_seconds() / 60.0
                    effective_timeout_minutes = (
                        self.PPP_AR_UPDATE_TIMEOUT_MINUTES if self.ppp_ar_enabled
                        else self.update_timeout_minutes
                    )
                    if minutes_since_success >= float(effective_timeout_minutes):
                        reason = st.get('last_failure_reason') or 'No successful coordinate update'
                        msg = (
                            f"No successful coordinate update for {minutes_since_success:.0f} minutes "
                            f"(timeout={effective_timeout_minutes}): {reason}"
                        )
                        logger.error(msg)
                        self._fail(msg)
                        self._running = False
                        break
                except Exception as timeout_err:
                    logger.warning(f"Timeout check failed: {timeout_err}")

                # Check if survey completed (use persisted start_time so completion is reliable after restart)
                if elapsed_hours >= self.target_hours:
                    logger.info(f"Target duration reached ({self.target_hours}h), performing final update...")
                    self._finalize_survey()
                    break

                if self.ppp_ar_enabled:
                    # Fixed-slot PPP-AR schedule: find all not-yet-attempted
                    # slots whose time has come. If a restart/downtime lets
                    # multiple slots become due at once (e.g. both the 4h
                    # and 8h slots), only the LATEST (highest) one is
                    # actually run and broadcast - a later slot always has
                    # more accumulated data and is therefore always more
                    # accurate, so an older due slot must never run and
                    # overwrite a newer one, whether in this same tick or
                    # on a later one. Earlier due-but-unattempted slots are
                    # marked attempted WITHOUT ever calling
                    # _run_ppp_ar_interim() for them - they are skipped
                    # outright, not deferred.
                    attempted_slots = set(self.state.get_ppp_ar_completed_slots())
                    due_unattempted = [
                        s for s in ppp_ar_slots
                        if s not in attempted_slots and elapsed_hours >= s
                    ]
                    # Full slot-decision trace on every tick, even when
                    # nothing is due yet - debug level so a complete
                    # PPP-AR scheduling history is reconstructable from
                    # logs alone if ever needed, without flooding info-
                    # level logs on every 10s poll tick.
                    logger.debug(
                        f"_survey_loop PPP-AR slot check: elapsed={elapsed_hours:.3f}h, "
                        f"all_slots={ppp_ar_slots}, attempted={sorted(attempted_slots)}, "
                        f"due_unattempted={due_unattempted}, "
                        f"selected={due_unattempted[-1] if due_unattempted else None}, "
                        f"stale_skipped={due_unattempted[:-1] if len(due_unattempted) > 1 else []}"
                    )
                    if due_unattempted:
                        latest_due = due_unattempted[-1]
                        # Skip any earlier due-but-unattempted slots WITHOUT
                        # running them - a later slot is always more
                        # accurate (more accumulated data), so an older
                        # slot must never be applied after a newer one is
                        # already due. This prevents the catch-up scenario
                        # where a stale 4h-slot result would overwrite an
                        # already-applied, more accurate 8h-slot result on
                        # a later tick.
                        for stale_slot in due_unattempted[:-1]:
                            logger.warning(
                                f"Skipping stale PPP-AR slot={stale_slot}h without "
                                f"running it - a later slot ({latest_due}h) is also "
                                f"due now and is always more accurate; never overwrite "
                                f"newer positioning data with older"
                            )
                            self.state.mark_ppp_ar_slot_attempted(stale_slot)
                        # Bounded retry-soon-on-failure for THIS slot only
                        # (see PPP_AR_SLOT_RETRY_MAX_ATTEMPTS's comment) -
                        # a transient failure (e.g. a network blip during
                        # product download) gets a few short-spaced
                        # attempts before this slot is given up on and
                        # marked attempted, rather than only ever trying
                        # once per 4h slot. Does not affect which slot is
                        # selected (still always latest_due) or the
                        # "mark attempted regardless of eventual outcome"
                        # rule - only the SAME slot is retried, never a
                        # different/older one.
                        slot_ok = False
                        for attempt_num in range(1, self.PPP_AR_SLOT_RETRY_MAX_ATTEMPTS + 1):
                            slot_ok = self._run_ppp_ar_interim(elapsed_hours, latest_due)
                            if slot_ok:
                                break
                            if attempt_num < self.PPP_AR_SLOT_RETRY_MAX_ATTEMPTS:
                                logger.warning(
                                    f"PPP-AR slot={latest_due}h attempt {attempt_num}/"
                                    f"{self.PPP_AR_SLOT_RETRY_MAX_ATTEMPTS} failed - "
                                    f"retrying in {self.PPP_AR_SLOT_RETRY_DELAY_SECONDS}s "
                                    f"(still within this same slot, not waiting for the "
                                    f"next fixed slot)"
                                )
                                time.sleep(self.PPP_AR_SLOT_RETRY_DELAY_SECONDS)
                            else:
                                logger.warning(
                                    f"PPP-AR slot={latest_due}h: all "
                                    f"{self.PPP_AR_SLOT_RETRY_MAX_ATTEMPTS} attempts failed - "
                                    f"giving up on this slot, will wait for the next fixed slot"
                                )
                        # Marked attempted regardless of success/failure,
                        # only after all retries above are exhausted (or
                        # one succeeded) - see _run_ppp_ar_interim()'s
                        # docstring.
                        self.state.mark_ppp_ar_slot_attempted(latest_due)
                else:
                    # Check if update due
                    if now >= next_update:
                        # Determine current interval based on elapsed time
                        if elapsed_hours < self.update_schedule['initial_period']:
                            interval = self.update_schedule['initial_interval']
                            logger.info(f"Interim update at {elapsed_hours:.2f}h (15-min schedule)")
                        else:
                            interval = self.update_schedule['later_interval']
                            logger.info(f"Interim update at {elapsed_hours:.2f}h (1-hour schedule)")

                        ok = self._perform_interim_update(elapsed_hours)

                        if ok:
                            next_update = now + timedelta(hours=interval)
                            logger.info(f"Next update scheduled in {interval*60:.0f} minutes")
                        else:
                            # Retry soon instead of waiting the whole interval.
                            # This makes the schedule 'real' as long as data becomes available.
                            next_update = now + timedelta(seconds=60)
                            logger.warning("Update failed; retry scheduled in 60 seconds")

                # Sleep briefly before next check
                time.sleep(10)  # Check every 10 seconds for faster completion

        except Exception as e:
            logger.error(f"Survey loop error: {e}", exc_info=True)
            self._fail(str(e))
            self._running = False
    
    def _perform_interim_update(self, elapsed_hours: float):
        """
        Perform interim position update (temporary coordinates)
        
        Updates RTKBase config with current best estimate.
        Marks as temporary in state.
        
        Args:
            elapsed_hours: Hours elapsed since survey start
        """
        logger.info(f"=== Interim Update ({elapsed_hours:.2f}h) ===")
        return self._perform_update(is_final=False)
    
    # PPP-static's convergence behavior differs fundamentally from SPP's:
    # a live 8-hour real test (Phase 2c) showed horizontal std shrinking
    # from ~5.2m to ~0.098m over the session - i.e. early interim updates
    # in a short-elapsed survey are EXPECTED to show large, unstable
    # values, not a malfunction. still_converging (computed below, Step 7)
    # is driven by estimate.horizontal_std_meters against this threshold,
    # NOT by elapsed time - an earlier version of this code used a fixed
    # elapsed-hours cutoff, but that number had no real source and was
    # removed.
    #
    # PPP_CONVERGENCE_STD_METERS: UNVERIFIED PLACEHOLDER, not derived from
    # the Phase 2c 8-hour test (that test's intermediate std values over
    # time were not logged/available - only the start (~5.2m) and end
    # (~0.098m) points are known) and not derived from any cited PPP
    # convergence literature. The one related, real, in-repo precedent is
    # gnss_parser.py's GNSSDataParser.max_std_3d default (0.05m = 5cm,
    # gnss_parser.py line ~90) - but that threshold governs per-EPOCH
    # quality filtering in a different, currently-unused code path (that
    # class is not wired into SurveyController - SPPProcessor/PPPProcessor
    # bypass it entirely), not a whole-ESTIMATE "PPP has converged"
    # judgment, so it is not a genuine match, only the closest existing
    # number in this codebase. 0.10m (10cm) is used here as a rough
    # "meaningfully better than SPP's meter-level noise floor, not yet at
    # final PPP-static cm-level accuracy" cutoff - THIS HAS NOT BEEN
    # VALIDATED AGAINST REAL CONVERGENCE DATA. Revisit once real
    # interim-update std progression is logged from an actual multi-hour
    # live survey.
    PPP_CONVERGENCE_STD_METERS = 0.10

    # UNVERIFIED PLACEHOLDER, not derived from any live PRIDE-PPPAR
    # fixed-vs-degraded comparison on this station (no station access
    # during development - see pride_pppar_processor.py's module
    # docstring for the same caveat on its own AR-related parsing). 90%
    # is a round, conservative-sounding threshold for "AR fix rate good
    # enough to trust this run's position over rnx2rtkp's", chosen only
    # because it is clearly above a marginal/mostly-float run and clearly
    # below a clean, fully-fixed one - NOT calibrated against real
    # wl_fix_rate/nl_fix_rate distributions from actual BaseStation PPP-AR
    # runs. Revisit once real fix-rate data has been logged from live
    # finalize-time PPP-AR runs (see _run_ppp_ar()'s logging below).
    PPP_AR_MIN_FIX_RATE_PERCENT = 90.0

    # Fixed PPP-AR interim slot interval (hours) - 0h, 4h, 8h, ... up to
    # (but excluding) target_hours, per Pesho's explicit "fixed absolute
    # slots, not floating last_success+interval" instruction. The final
    # slot (target_hours) is handled separately by _finalize_survey(),
    # never by this interim schedule.
    PPP_AR_SLOT_INTERVAL_HOURS = 4.0

    # Hard-timeout threshold (minutes) used INSTEAD OF
    # update_timeout_minutes when self.ppp_ar_enabled - the normal
    # update_timeout_minutes (default 60min) is calibrated for the
    # rnx2rtkp path's ~15min/1h interval-with-60s-retry-on-failure
    # schedule, and would spuriously hard-fail a PPP-AR survey roughly an
    # hour after every successful 4h slot, since last_success_update_time
    # legitimately does not change between fixed slots. Set well above
    # PPP_AR_SLOT_INTERVAL_HOURS so only multiple consecutive missed/
    # skipped slots (not the normal multi-hour gap between successful
    # ones) trip it. UNCALIBRATED - a round "2 slot intervals + margin"
    # choice, not derived from any live PPP-AR failure-rate data.
    PPP_AR_UPDATE_TIMEOUT_MINUTES = int(PPP_AR_SLOT_INTERVAL_HOURS * 2 * 60) + 60

    # Bounded, short-window retry-on-failure for the CURRENT due slot -
    # confirmed live on BaseStation: a single transient network/DNS blip
    # during one slot's product download (pdp3 exits 0 but produces no
    # pos_* file - see pride_pppar_processor.py's process_ppp_ar()) meant
    # that slot was marked "attempted" and not retried until the NEXT
    # fixed 4h slot; two such transient failures in a row (4h then 8h)
    # consumed nearly the entire PPP_AR_UPDATE_TIMEOUT_MINUTES (540min/9h)
    # budget before a 3rd slot even had a chance to run, aborting an
    # otherwise-recoverable 14h survey over what was, in the end, just a
    # transient mirror/DNS issue - not a real station or data problem.
    #
    # Fix: when the CURRENT (latest-due) slot's attempt fails, retry it up
    # to PPP_AR_SLOT_RETRY_MAX_ATTEMPTS times with
    # PPP_AR_SLOT_RETRY_DELAY_SECONDS between attempts, all still within
    # the SAME slot (never marked "attempted" until every retry is
    # exhausted or one succeeds) - this does NOT change the "only the
    # latest due slot ever runs, older due-but-unattempted slots are
    # skipped without running" invariant (see _survey_loop()'s comment):
    # retries only ever apply to the slot that was already selected to
    # run, they never cause an older slot to run or re-run. Deliberately
    # small/bounded (3 attempts, 2 minutes apart = at most ~6 extra
    # minutes per slot) rather than an open-ended retry loop, so a
    # persistent (non-transient) failure still gives up promptly and lets
    # the survey continue waiting for the next slot rather than blocking
    # the survey loop for an extended period.
    PPP_AR_SLOT_RETRY_MAX_ATTEMPTS = 3
    PPP_AR_SLOT_RETRY_DELAY_SECONDS = 120

    def _apply_geodetic_position(self,
                                  lat: float, lon: float, height: float,
                                  obs_file: Path,
                                  is_final: bool,
                                  ppp_backend: str,
                                  position_std: Dict[str, float],
                                  num_epochs: int,
                                  quality_metrics: Dict,
                                  extra_position_fields: Optional[Dict] = None) -> bool:
        """
        Shared geoid-correction / ITRF2020->BGS2005 transform / RTCM
        broadcast / state-update pipeline - extracted from _perform_update()'s
        former Steps 6-9 so BOTH the rnx2rtkp path (_perform_update()) and
        the PRIDE-PPPAR-only path (_run_ppp_ar_interim()/_finalize_survey()
        when self.ppp_ar_enabled) can reach an actual RTCM broadcast, not
        just an in-memory lat/lon/height.

        Before this extraction, PRIDE-PPPAR's result only ever overwrote an
        rnx2rtkp result's lat/lon/height AFTER _perform_update() had already
        run the full geoid/BGS2005/broadcast pipeline once - workable only
        because rnx2rtkp always ran first. A PRIDE-PPPAR-ONLY mode (no
        rnx2rtkp at all) has no such pipeline run to overwrite, so this
        method exists to give it one of its own.

        Args:
            lat, lon, height: raw geodetic position (ITRF2020/WGS84-family
                datum) BEFORE geoid/BGS2005 processing - rnx2rtkp's
                estimate.lat/lon/height, or PRIDE-PPPAR's
                parse_ppp_ar_result()['lat'/'lon'/'height'].
            obs_file: RINEX observation file this position was derived
                from - needed for extract_observation_epoch() (BGS2005
                transform's t_obs).
            is_final: whether this is the survey's final update.
            ppp_backend: 'rnx2rtkp' | 'pride-pppar' - recorded verbatim in
                the position audit trail dict.
            position_std: dict with std_lat/std_lon/std_height/
                std_h_meters - caller-supplied since rnx2rtkp's multi-epoch
                estimator and PRIDE-PPPAR's single-point Sx/Sy/Sz have no
                common shape; each caller builds what it actually has.
            num_epochs: epoch count for state's num_epochs field (0/1 for
                PRIDE-PPPAR's single-point result).
            quality_metrics: dict merged into state's quality_metrics -
                caller-supplied for the same reason as position_std.
            extra_position_fields: additional keys merged into the
                position dict before it's persisted (e.g. PRIDE-PPPAR's
                ar_wl_fix_rate/ar_nl_fix_rate) - None for the plain
                rnx2rtkp path.

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
            # Step 6: Compute orthometric (MSL) height via geoid model.
            # Per АГКК's official requirement, this IS the height broadcast
            # via RTCM 1005/1006 below (not ellipsoidal) - see the
            # fallback behavior below when no geoid model is loaded / the
            # position is outside grid bounds.
            h_ortho = self.geoid.ellipsoidal_to_orthometric(lat, lon, height)

            if h_ortho is None:
                logger.info("Geoid lookup result: unavailable (no geoid model loaded / position outside grid bounds) - orthometric height unavailable")
            else:
                geoid_sep = height - h_ortho
                logger.info(f"Geoid lookup result: h_ortho={h_ortho:.3f}m (correction {geoid_sep:+.3f}m → Height MSL: {h_ortho:.3f}m)")

            # Step 7: ITRF2020 -> BGS2005 transformation. Per Инструкция №
            # РД-02-20-25 от 20.09.2011 г., Чл.22, ал.1: relative GNSS
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
            logger.debug(f"BGS2005 transform: input={{'lat': {lat}, 'lon': {lon}, 'height': {height}, 't_obs': {t_obs}}}, "
                         f"output={bgs2005}")

            # Step 8: Update RTKBase configuration
            # CRITICAL: broadcast the BGS2005-transformed, ORTHOMETRIC
            # (MSL/geoid) height (h_ortho from Step 6), never
            # bgs2005['height_m'] (ellipsoidal) or the raw input height.
            # This is the value str2str -p embeds into RTCM 1005/1006 for
            # rover baseline calculations. Per АГКК's official requirement,
            # base station RTCM broadcast positions must carry orthometric
            # height computed from the .ggf geoid model, not
            # ellipsoidal/WGS84 height.
            #
            # Fallback: if no geoid model is loaded / the position is
            # outside the loaded grid's bounds (h_ortho is None), fall back
            # to ellipsoidal height for this update with an explicit
            # warning - not a hard failure, since a temporarily-unavailable
            # geoid correction should not stop the survey from broadcasting
            # a usable (if height-type-inconsistent) position.
            broadcast_height_type = 'orthometric'
            if h_ortho is not None:
                broadcast_height = h_ortho
            else:
                broadcast_height = bgs2005['height_m']
                broadcast_height_type = 'ellipsoidal'
                logger.warning(
                    "No geoid model loaded / position is outside grid "
                    "bounds - falling back to ellipsoidal height for this "
                    "update (cannot broadcast orthometric height without a "
                    "geoid correction to compute it from)."
                )

            logger.info(f"RTCM broadcast height type this session: {broadcast_height_type} "
                        f"({broadcast_height:.3f}m)")

            if is_final:
                logger.info("🎯 FINAL UPDATE - Applying permanent coordinates (BGS2005)...")
            else:
                logger.info("⏱ INTERIM UPDATE - Applying temporary coordinates (BGS2005)...")

            if self.rtkbase.update_position(bgs2005['lat_dd'], bgs2005['lon_dd'], broadcast_height):
                if is_final:
                    logger.info(f"✓ RTCM broadcast: final configuration applied successfully "
                                f"(lat={bgs2005['lat_dd']:.8f}, lon={bgs2005['lon_dd']:.8f}, height={broadcast_height:.3f})")
                else:
                    logger.info(f"✓ RTCM broadcast: temporary configuration updated "
                                f"(lat={bgs2005['lat_dd']:.8f}, lon={bgs2005['lon_dd']:.8f}, height={broadcast_height:.3f})")

                # Restart services on every update so new coords take effect immediately
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
            # Explicit float() casts: values coming from rnx2rtkp's
            # numpy-based estimator would otherwise leak numpy.float64 into
            # the JSON-serialized state - kept here since this method now
            # owns that serialization boundary for both backends.
            #
            # position['height'] holds the height TYPE ACTUALLY BROADCAST
            # this update (broadcast_height, computed above - ellipsoidal
            # by default, or orthometric if broadcast_height_type ==
            # 'orthometric') - the value actually written to
            # settings.conf/RTCM. 'height_ellipsoidal' and 'height_msl' are
            # both always recorded alongside it (regardless of which was
            # broadcast) for audit purposes, so it is always possible to
            # tell after the fact which height type a given update
            # actually sent, and what the other one would have been. The
            # raw ITRF2020 estimate is likewise kept for display/
            # diagnostics only, never re-broadcast.
            position = {
                'lat': float(bgs2005['lat_dd']),
                'lon': float(bgs2005['lon_dd']),
                'height': float(broadcast_height),  # ACTUALLY BROADCAST this update - orthometric (MSL), or ellipsoidal fallback if no geoid model - see broadcast_height_type
                'broadcast_height_type': broadcast_height_type,  # 'orthometric' (standard) | 'ellipsoidal' (fallback when no geoid model loaded) - audit trail
                'height_ellipsoidal': float(bgs2005['height_m']),  # BGS2005 ellipsoidal, always recorded regardless of what was broadcast
                'height_msl': float(h_ortho) if h_ortho is not None else None,  # orthometric (MSL) of the ITRF2020 estimate, always recorded regardless of what was broadcast
                'coordinate_system': 'BGS2005',
                'itrf2020_lat': float(lat),
                'itrf2020_lon': float(lon),
                'itrf2020_height': float(height),
                # Which PPP backend produced the broadcast lat/lon/height
                # above - see _perform_update()/_run_ppp_ar_interim()/
                # _finalize_survey() callers.
                'ppp_backend': ppp_backend,
            }
            if extra_position_fields:
                position.update(extra_position_fields)

            self.state.update_progress(
                position=position,
                position_std=position_std,
                num_epochs=num_epochs,
                quality_metrics=quality_metrics
            )

            if is_final:
                logger.info(f"✓ FINAL UPDATE complete ({ppp_backend}) - Epochs: {num_epochs}")
            else:
                logger.info(f"✓ Interim update complete ({ppp_backend}) - Epochs: {num_epochs}"
                            + (" (still converging)" if quality_metrics.get('still_converging') else ""))

            return True

        except Exception as e:
            logger.error(f"Failed to apply geodetic position: {e}", exc_info=True)
            try:
                self.state.record_update_failure(f"Unhandled exception: {e}")
            except Exception:
                pass
            return False

    def _perform_update(self, is_final: bool = False) -> bool:
        """
        Perform position update using RINEX + PPP-static workflow:
        1. Find latest raw GNSS log file
        2. Convert to RINEX (obs + nav)
        3. Fetch CDDIS precise orbit/clock products, process with
           rnx2rtkp -p 8 (PPP-static)
        4. Parse position solutions
        5. Estimate mean position with outlier rejection
        6-9. Geoid correction, ITRF2020->BGS2005 transform, RTCM broadcast,
           state update - delegated to _apply_geodetic_position() (shared
           with the PRIDE-PPPAR-only path - see that method's docstring).
        """
        try:
            # Step 1: Find latest raw data file
            raw_file = self.rtkbase.get_data_file()

            if not raw_file or not raw_file.exists():
                logger.warning("No raw data file found - waiting for data...")
                self.state.record_update_failure("No raw data file found")
                return False

            logger.info(f"Processing raw file: {raw_file.name} ({raw_file.stat().st_size / 1024:.1f} KB)")

            # Step 2: Convert to RINEX
            rinex_dir = self.work_dir / "rinex"
            rinex_result = self.rinex.convert_raw_to_rinex_obs(raw_file, rinex_dir)

            if not rinex_result:
                logger.error("RINEX conversion failed")
                self.state.record_update_failure("RINEX conversion failed")
                return False

            obs_file, nav_file = rinex_result
            logger.info(f"✓ RINEX files created: {obs_file.name}, {nav_file.name if nav_file else 'N/A'}")

            # Step 3: Fetch CDDIS precise products for the configured tier,
            # then process with rnx2rtkp -p 8 (PPP-static). No SPP fallback
            # on any failure here - per Pesho's explicit "no fallback, no
            # silent start" decision (already established for
            # ppp_downloader.py's own error handling), a failed fetch or a
            # failed PPP run surfaces as a failed update like any other
            # failure mode in this method, not a silent degrade to SPP.
            survey_status = self.state.get_status()
            survey_start_raw = survey_status.get('start_time')
            survey_start_time = datetime.fromisoformat(survey_start_raw) if survey_start_raw else datetime.utcnow()

            try:
                products = self.ppp_downloader.fetch_products(self.ppp_tier, survey_start_time)
            except PPPDownloaderError as e:
                logger.error(f"Precise product fetch failed ({self.ppp_tier}): {e}")
                self.state.record_update_failure(f"Precise product fetch failed ({self.ppp_tier}): {e}")
                return False

            sp3_file = products.get('sp3')
            clk_file = products.get('clk')  # None for ultra-rapid - process_ppp() handles this
            logger.info(f"✓ Precise products ready: sp3={sp3_file.name if sp3_file else 'N/A'}, "
                        f"clk={clk_file.name if clk_file else '(none - ultra-rapid, SP3-embedded clocks)'}")

            pos_file = self.spp.process_ppp(obs_file, sp3_file, nav_file=nav_file, clk_file=clk_file)

            if not pos_file:
                logger.error("PPP-static processing failed")
                self.state.record_update_failure("PPP-static processing failed (rnx2rtkp -p 8)")
                return False

            logger.info(f"✓ PPP-static position file: {pos_file.name}")

            # Step 4: Parse positions - parse_position_file() is unchanged
            # from SPPProcessor (RTKLIB's -f 2 output format is
            # mode-independent, confirmed Phase 2c) and reused as-is here.
            positions = self.spp.parse_position_file(pos_file)

            if not positions:
                logger.warning("No positions in PPP-static output")
                self.state.record_update_failure("No positions in PPP-static output")
                return False

            # Accept common RTKLIB quality flags.
            # 1=FIX, 2=FLOAT, 4=DGPS, 5=SINGLE, 6=PPP (confirmed live,
            # Phase 2c: rnx2rtkp -p 8 reports Q=6 for PPP solutions)
            quality_positions = [p for p in positions if p.get('Q') in (1, 2, 4, 5, 6)]

            if not quality_positions:
                logger.warning(f"No PPP-static solutions found (total positions: {len(positions)})")
                self.state.record_update_failure("No usable solutions in PPP-static output (quality filter)")
                return False

            logger.info(f"Found {len(quality_positions)} PPP-static solutions")

            # Step 5: Estimate mean position
            estimate = self.estimator.estimate_position(quality_positions)

            if not estimate:
                logger.error("Failed to estimate position")
                self.state.record_update_failure("Failed to estimate position (insufficient/unstable data)")
                return False

            logger.info(f"Position estimate (ITRF2020): {estimate.lat:.8f}°, {estimate.lon:.8f}°, {estimate.height:.3f}m")
            logger.info(f"Std: H={estimate.horizontal_std_meters*1000:.1f}mm, V={estimate.std_height*1000:.1f}mm")

            # PPP-static convergence is slow relative to SPP (see
            # PPP_CONVERGENCE_STD_METERS above) - interim updates whose
            # horizontal std is still above that (unverified placeholder)
            # threshold are flagged so the UI can show "still converging"
            # instead of implying the shown accuracy is final. Driven by
            # the actual estimate quality (estimate.horizontal_std_meters,
            # already computed in Step 5 above), not elapsed time.
            # bool(...) cast: estimate.horizontal_std_meters is
            # numpy.float64 (position_estimator.py's np.sqrt()-derived
            # property), so the ">" comparison produces numpy.bool_, not a
            # native bool - confirmed live on BaseStation as the cause of
            # "Object of type bool is not JSON serializable" at save_state()
            # time. Explicit cast here, consistent with the float() casts
            # applied to the other numpy-derived quality_metrics fields
            # below.
            still_converging = bool((not is_final) and (estimate.horizontal_std_meters > self.PPP_CONVERGENCE_STD_METERS))

            # Grep-able std-vs-time data point, logged on every update
            # (interim and final) - PPP_CONVERGENCE_STD_METERS is an
            # unverified placeholder (see its definition above); this line
            # exists specifically to accumulate real elapsed/std pairs
            # from live surveys so that placeholder can be replaced with a
            # calibrated value once enough real progressions are recorded.
            elapsed_hours_for_log = (datetime.utcnow() - survey_start_time).total_seconds() / 3600
            logger.info(
                f"PPP convergence: elapsed={elapsed_hours_for_log:.2f}h "
                f"std={estimate.horizontal_std_meters:.3f}m "
                f"still_converging={still_converging}"
            )

            # Steps 6-9 (geoid correction, ITRF2020->BGS2005 transform,
            # RTCM broadcast, state update) - delegated to the shared
            # helper (see its docstring for why this is now shared with
            # the PRIDE-PPPAR-only path).
            return self._apply_geodetic_position(
                lat=estimate.lat,
                lon=estimate.lon,
                height=estimate.height,
                obs_file=obs_file,
                is_final=is_final,
                ppp_backend='rnx2rtkp',
                position_std={
                    'std_lat': float(estimate.std_lat),
                    'std_lon': float(estimate.std_lon),
                    'std_height': float(estimate.std_height),
                    'std_h_meters': float(estimate.horizontal_std_meters),
                },
                num_epochs=estimate.num_epochs,
                quality_metrics={
                    'mean_sats': float(estimate.mean_sats) if hasattr(estimate, 'mean_sats') else 0,
                    'rejected_epochs': int(estimate.rejected_epochs) if hasattr(estimate, 'rejected_epochs') else 0,
                    'is_final': is_final,
                    'ppp_tier': self.ppp_tier,
                    'still_converging': still_converging,
                },
            )

        except Exception as e:
            logger.error(f"Update failed: {e}", exc_info=True)
            try:
                self.state.record_update_failure(f"Unhandled exception: {e}")
            except Exception:
                pass
            return False
    
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

    def _cleanup_old_ppp_ar_slot_dirs(self, ppp_ar_root: Path, keep_dir: Path) -> None:
        """
        Prune old per-slot PRIDE-PPPAR work directories under ppp_ar_root,
        keeping the PPP_AR_SLOT_DIRS_TO_KEEP most-recently-created ones
        (by directory mtime) plus keep_dir itself (the one about to be
        used for the current attempt, so it's never pruned even if it
        happens to already exist and be older than others - shouldn't
        normally happen given the run-id suffix, but kept defensive).

        Best-effort only: any failure to list/remove a stale directory is
        logged and otherwise ignored - a pruning failure must never abort
        or fail the PPP-AR run itself.
        """
        try:
            if not ppp_ar_root.is_dir():
                return
            slot_dirs = [
                p for p in ppp_ar_root.iterdir()
                if p.is_dir() and p.name.startswith("slot_") and p != keep_dir
            ]
            slot_dirs.sort(key=lambda p: p.stat().st_mtime, reverse=True)
            for stale_dir in slot_dirs[self.PPP_AR_SLOT_DIRS_TO_KEEP:]:
                try:
                    shutil.rmtree(stale_dir)
                    logger.debug(f"_cleanup_old_ppp_ar_slot_dirs: removed stale slot dir {stale_dir}")
                except Exception as e:
                    logger.warning(f"_cleanup_old_ppp_ar_slot_dirs: failed to remove stale slot dir {stale_dir}: {e}")
        except Exception as e:
            logger.warning(f"_cleanup_old_ppp_ar_slot_dirs: pruning failed (non-fatal): {e}")

    def _run_ppp_ar(self, slot_label: str = "unknown") -> Optional[Dict]:
        """
        Run PRIDE-PPPAR (pdp3) for ambiguity-resolved PPP-static
        positioning - the shared worker behind BOTH:
        - the PRIDE-PPPAR-only interim path (_run_ppp_ar_interim(),
          fixed-slot schedule, when self.ppp_ar_enabled), and
        - the finalize-time step (_finalize_survey(), when
          self.ppp_ar_enabled - either as a pure PRIDE-PPPAR final result,
          or - in the older, no-longer-default overwrite mode - layered on
          top of an already-run rnx2rtkp result).

        Independently re-locates/re-converts the latest raw GNSS log to
        RINEX rather than threading obs_file state through
        _perform_update() - both self.rtkbase.get_data_file() and
        self.rinex.convert_raw_to_rinex_obs() are idempotent lookups
        against the same latest raw file / rinex_dir, so redoing them
        here is cheap and keeps this method fully self-contained (also
        needed since, with ppp_ar_enabled=True, _perform_update() never
        runs at all - see _finalize_survey()/_run_ppp_ar_interim()).

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

        try:
            pride = PridePpparProcessor(rtkbase_root=self.rtkbase.rtkbase_root)
        except Pdp3NotFoundError as e:
            logger.warning(f"_run_ppp_ar: PPP-AR enabled but pdp3 not available - skipping this run: {e}")
            return None

        raw_file = self.rtkbase.get_data_file()
        if not raw_file or not raw_file.exists():
            logger.warning("_run_ppp_ar: no raw data file found - skipping this run")
            return None

        logger.debug(f"_run_ppp_ar: raw_file={raw_file}")

        rinex_dir = self.work_dir / "rinex"
        rinex_result = self.rinex.convert_raw_to_rinex_obs(raw_file, rinex_dir)
        if not rinex_result:
            logger.warning("_run_ppp_ar: RINEX conversion failed - skipping this run")
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

        pos_file = pride.process_ppp_ar(obs_file, work_dir=ppp_ar_dir)

        # Prune old slot directories AFTER this attempt (whether it
        # succeeded or failed) - never before, so a failed attempt's own
        # directory is never at risk of being pruned by its own cleanup
        # pass, and always runs regardless of outcome so failed-attempt
        # directories don't escape the retention limit either.
        self._cleanup_old_ppp_ar_slot_dirs(ppp_ar_root, keep_dir=ppp_ar_dir)

        if not pos_file:
            logger.warning(
                f"_run_ppp_ar: pdp3 run failed or produced no result - skipping this run "
                f"(obs_duration={obs_duration_minutes:.1f}min)" if obs_duration_minutes is not None
                else "_run_ppp_ar: pdp3 run failed or produced no result - skipping this run (obs_duration=unknown)"
            )
            return None

        result = pride.parse_ppp_ar_result(pos_file)
        if not result:
            logger.warning(
                f"_run_ppp_ar: could not parse pdp3 result - skipping this run "
                f"(obs_duration={obs_duration_minutes:.1f}min)" if obs_duration_minutes is not None
                else "_run_ppp_ar: could not parse pdp3 result - skipping this run (obs_duration=unknown)"
            )
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
        return result

    def _ppp_ar_fix_rate_ok(self, ppp_ar_result: Dict) -> bool:
        """
        Whether a PRIDE-PPPAR result's wide-lane/narrow-lane fix rates
        both clear PPP_AR_MIN_FIX_RATE_PERCENT - shared threshold check
        used by both _run_ppp_ar_interim() and _finalize_survey().
        """
        wl = ppp_ar_result.get('wl_fix_rate')
        nl = ppp_ar_result.get('nl_fix_rate')
        return (
            wl is not None and nl is not None and
            wl >= self.PPP_AR_MIN_FIX_RATE_PERCENT and
            nl >= self.PPP_AR_MIN_FIX_RATE_PERCENT
        )

    def _log_ppp_ar_attempt(self, slot_label: str, result: str, reason: str,
                             ppp_ar_result: Optional[Dict] = None) -> None:
        """
        Log one single-line, grep-able PPP-AR attempt summary, fired from
        EVERY return path of both _run_ppp_ar_interim() and the
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

    def _run_ppp_ar_interim(self, elapsed_hours: float, slot_hours: float) -> bool:
        """
        Run one PRIDE-PPPAR-only interim update, for the fixed-slot
        schedule (_survey_loop(), when self.ppp_ar_enabled) - the
        PRIDE-PPPAR analogue of _perform_interim_update()/_perform_update(),
        but using _run_ppp_ar() instead of rnx2rtkp/CDDIS, and applied only
        if the fix rate clears PPP_AR_MIN_FIX_RATE_PERCENT.

        Never raises. This method itself does not retry - _survey_loop()
        (the caller) wraps this call in a small, bounded retry loop
        (PPP_AR_SLOT_RETRY_MAX_ATTEMPTS, short-spaced) so a transient
        failure (e.g. a product-download network blip) gets a few more
        tries within the SAME slot before being given up on, rather than
        every failure automatically waiting a full PPP_AR_SLOT_INTERVAL_HOURS
        for the next fixed slot (fixed after a real 14h survey was aborted
        by the survey-wide watchdog over what was, in the end, just two
        consecutive transient network failures - see
        PPP_AR_SLOT_RETRY_MAX_ATTEMPTS's own comment for the full story).
        _survey_loop() marks slot_hours as attempted only once its retry
        loop is exhausted (or a retry succeeds), so a failed/skipped run
        is still never retried past that point until the next fixed slot.

        Args:
            elapsed_hours: hours elapsed since survey start (for logging).
            slot_hours: the fixed schedule slot (0, 4, 8, ...) this run
                corresponds to (for logging).

        Returns:
            True if a PRIDE-PPPAR position was successfully computed AND
            applied (broadcast) for this slot, False if skipped for any
            reason (pdp3 unavailable, run failure, parse failure, fix
            rate below threshold, or broadcast/state-update failure) -
            False is the expected, non-alarming outcome for "wait for the
            next slot", not a survey-level failure.
        """
        slot_label = f"{slot_hours}h"
        logger.info(f"=== PPP-AR Interim Update (slot={slot_hours}h, elapsed={elapsed_hours:.2f}h) ===")

        ppp_ar_result = self._run_ppp_ar(slot_label=slot_label)
        if ppp_ar_result is None:
            logger.warning(f"PPP-AR interim slot={slot_hours}h: no result - "
                            f"this attempt failed (caller may retry within this same slot)")
            self._log_ppp_ar_attempt(slot_label, "FAILED", "no result from _run_ppp_ar (pdp3 unavailable/no raw file/RINEX conversion failed/run failed/parse failed)")
            return False

        if not self._ppp_ar_fix_rate_ok(ppp_ar_result):
            logger.info(
                f"PPP-AR interim slot={slot_hours}h: fix rate below threshold "
                f"(WL={ppp_ar_result.get('wl_fix_rate')}%, "
                f"NL={ppp_ar_result.get('nl_fix_rate')}%, need >= "
                f"{self.PPP_AR_MIN_FIX_RATE_PERCENT}%) - skipping this slot"
            )
            self._log_ppp_ar_attempt(slot_label, "SKIPPED", "fix rate below threshold", ppp_ar_result)
            return False

        logger.info(
            f"✓ PPP-AR interim slot={slot_hours}h: fix rate cleared threshold "
            f"(WL={ppp_ar_result['wl_fix_rate']}%, NL={ppp_ar_result['nl_fix_rate']}%) - "
            f"applying position"
        )

        applied = self._apply_geodetic_position(
            lat=ppp_ar_result['lat'],
            lon=ppp_ar_result['lon'],
            height=ppp_ar_result['height'],
            obs_file=ppp_ar_result['obs_file'],
            is_final=False,
            ppp_backend='pride-pppar',
            position_std={
                # PRIDE-PPPAR's pos_* file reports ECEF-frame Sx/Sy/Sz
                # (see pride_pppar_processor.py), not local-frame N/E/U
                # std the way rnx2rtkp's estimator does - no direct
                # equivalent of std_lat/std_lon/std_height/std_h_meters
                # is computed here (would require an ECEF->local frame
                # rotation not otherwise needed by this pipeline). Left
                # as 0.0 placeholders rather than fabricating a
                # conversion; sig0 (in quality_metrics below) is the real
                # per-run quality signal for this backend.
                'std_lat': 0.0,
                'std_lon': 0.0,
                'std_height': 0.0,
                'std_h_meters': 0.0,
            },
            num_epochs=int(ppp_ar_result.get('nobs', 0)),
            quality_metrics={
                'is_final': False,
                'ppp_tier': self.ppp_tier,
                'still_converging': False,  # PRIDE-PPPAR is a single-point AR solution, not an accumulating estimator - no analogous "still converging" state
                'ppp_ar_sig0': ppp_ar_result.get('sig0'),
                'ppp_ar_wl_fix_rate': ppp_ar_result.get('wl_fix_rate'),
                'ppp_ar_nl_fix_rate': ppp_ar_result.get('nl_fix_rate'),
            },
            extra_position_fields={
                'ar_wl_fix_rate': ppp_ar_result.get('wl_fix_rate'),
                'ar_nl_fix_rate': ppp_ar_result.get('nl_fix_rate'),
            },
        )

        if not applied:
            logger.warning(f"PPP-AR interim slot={slot_hours}h: broadcast/state update failed - "
                            f"skipping this slot")
            self._log_ppp_ar_attempt(slot_label, "FAILED", "apply_geodetic_position failed (geoid/BGS2005/broadcast step)", ppp_ar_result)
            return False

        self._log_ppp_ar_attempt(slot_label, "SUCCESS", "applied successfully", ppp_ar_result)
        return True

    def _finalize_survey(self):
        """
        Finalize survey at completion:
        1. Process all accumulated data with RINEX
        2. Generate final position estimate
        3. Update configuration with best estimate
        4. Mark survey as completed
        5. Restart main service to apply new coordinates
        6. Stop file logging to prevent disk space issues

        ARCHITECTURE: if self.ppp_ar_enabled, this is a PRIDE-PPPAR-ONLY
        survey end to end - step 2's rnx2rtkp/CDDIS final update
        (_perform_update(is_final=True)) is SKIPPED ENTIRELY, not merely
        overwritten afterward (that was the OLD behavior, before this was
        made a full architectural switch rather than an overlay). Only
        _run_ppp_ar() runs, and only if its wide-lane/narrow-lane fix
        rates both clear PPP_AR_MIN_FIX_RATE_PERCENT is its result applied
        via _apply_geodetic_position() (the same shared broadcast/state
        pipeline _perform_update() uses). If PRIDE-PPPAR is unavailable,
        fails, or its fix rate doesn't clear the threshold, this survey's
        final update simply does not happen this run - there is no
        rnx2rtkp result to fall back to any more when ppp_ar_enabled is
        True (by design - see this session's explicit instruction). Any
        previously-recorded current_position (e.g. from PRIDE-PPPAR
        interim slots via _run_ppp_ar_interim()) is still used as the
        completed-survey position via before_pos below, so a failed FINAL
        run does not necessarily mean an empty result.
        """
        try:
            logger.info("=" * 60)
            logger.info("🎯 FINALIZING SURVEY - Processing complete 24h dataset...")
            logger.info("=" * 60)

            # Snapshot any previously computed position so we can still complete even if final update fails
            before_status = self.state.get_status()
            before_pos = before_status.get('current_position')

            if self.ppp_ar_enabled:
                # PRIDE-PPPAR-ONLY final update - rnx2rtkp/CDDIS is never
                # invoked when ppp_ar_enabled is True (see docstring).
                logger.info("PPP-AR enabled: running PRIDE-PPPAR-only final update (rnx2rtkp/CDDIS skipped)")
                try:
                    ppp_ar_result = self._run_ppp_ar(slot_label="final")
                    if ppp_ar_result is None:
                        logger.warning(
                            "PPP-AR final run produced no result - no final update this run "
                            "(any prior interim PRIDE-PPPAR position, if any, is still used below)"
                        )
                        self._log_ppp_ar_attempt("final", "FAILED", "no result from _run_ppp_ar (pdp3 unavailable/no raw file/RINEX conversion failed/run failed/parse failed)")
                    elif not self._ppp_ar_fix_rate_ok(ppp_ar_result):
                        logger.warning(
                            f"PPP-AR final run: fix rate below threshold "
                            f"(WL={ppp_ar_result.get('wl_fix_rate')}%, "
                            f"NL={ppp_ar_result.get('nl_fix_rate')}%, need >= "
                            f"{self.PPP_AR_MIN_FIX_RATE_PERCENT}%) - no final update this run"
                        )
                        self._log_ppp_ar_attempt("final", "SKIPPED", "fix rate below threshold", ppp_ar_result)
                    else:
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
                                # Same "no direct N/E/U std available"
                                # caveat as _run_ppp_ar_interim() - see
                                # that method's comment.
                                'std_lat': 0.0,
                                'std_lon': 0.0,
                                'std_height': 0.0,
                                'std_h_meters': 0.0,
                            },
                            num_epochs=int(ppp_ar_result.get('nobs', 0)),
                            quality_metrics={
                                'is_final': True,
                                'ppp_tier': self.ppp_tier,
                                'still_converging': False,
                                'ppp_ar_sig0': ppp_ar_result.get('sig0'),
                                'ppp_ar_wl_fix_rate': ppp_ar_result.get('wl_fix_rate'),
                                'ppp_ar_nl_fix_rate': ppp_ar_result.get('nl_fix_rate'),
                            },
                            extra_position_fields={
                                'ar_wl_fix_rate': ppp_ar_result.get('wl_fix_rate'),
                                'ar_nl_fix_rate': ppp_ar_result.get('nl_fix_rate'),
                            },
                        )
                        if final_applied:
                            self._log_ppp_ar_attempt("final", "SUCCESS", "applied successfully", ppp_ar_result)
                        else:
                            self._log_ppp_ar_attempt("final", "FAILED", "apply_geodetic_position failed (geoid/BGS2005/broadcast step)", ppp_ar_result)
                except Exception as ppp_ar_err:
                    logger.error(f"PPP-AR final step failed: {ppp_ar_err}", exc_info=True)
                    self._log_ppp_ar_attempt("final", "FAILED", f"unhandled exception: {ppp_ar_err}")
            else:
                # Standard rnx2rtkp/CDDIS final update - unchanged.
                self._perform_update(is_final=True)

            # Get current state
            status = self.state.get_status()
            pos = status.get('current_position') or before_pos

            if pos:
                std = status.get('position_std', {})

                self.state.complete_survey(pos)

                logger.info("=" * 60)
                logger.info("✓ SURVEY COMPLETED SUCCESSFULLY")
                # pos['lat']/lon are the BGS2005-transformed broadcast
                # coordinate (see _perform_update() Step 7/9), and
                # pos['height'] is whichever height type was actually
                # broadcast (pos['broadcast_height_type']) per the АГКК
                # requirement - orthometric by default, ellipsoidal only as
                # fallback when no geoid model is available - not the raw
                # ITRF2020 PPP estimate either way.
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
                    logger.info(f"✓ Applying coordinates to RTKBase (BGS2005, "
                                f"{pos.get('broadcast_height_type', 'ellipsoidal')} height): "
                                f"{pos['lat']:.8f} {pos['lon']:.8f} {pos['height']:.3f}")
                    if self.rtkbase.update_position(pos['lat'], pos['lon'], pos['height']):
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
                        import time
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
                # the final error alone. Falls back to the old generic
                # message when self.ppp_ar_enabled is False (rnx2rtkp
                # path) or no PPP-AR attempt was ever logged this
                # instance's lifetime.
                if self.ppp_ar_enabled and self._last_ppp_ar_attempt_summary:
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
        status = self.state.get_status()

        # Auto-apply coordinates if survey is completed but not yet applied.
        # pos['lat']/lon are the BGS2005-transformed broadcast coordinate,
        # and pos['height'] is whichever height type was actually
        # broadcast for this survey (pos['broadcast_height_type']) - see
        # _perform_update()'s Step 7/8/9 - not raw ITRF2020 either way, no
        # re-transformation needed here.
        try:
            if status.get('survey_state') == SurveyState.COMPLETED.value and not status.get('applied'):
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

        status['is_running'] = self._running
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
            self._fail("GNSS receiver not ready (service inactive or invalid format). Configure the receiver in Main Service settings before starting Auto Survey-In.")
            return False

        logger.info("Recovering previous survey session...")

        # Ensure controller uses persisted target_hours/ppp_tier (so loop
        # completion and precise-product fetching match what was actually
        # started, not this instance's just-initialized defaults)
        try:
            status = self.state.get_status()
            target_hours = status.get('target_hours')
            if isinstance(target_hours, (int, float)) and target_hours > 0:
                self.target_hours = int(target_hours)
            ppp_tier = status.get('ppp_tier')
            if ppp_tier in ('ultra-rapid', 'rapid', 'final'):
                self.ppp_tier = ppp_tier
            ppp_ar_enabled = status.get('ppp_ar_enabled')
            if isinstance(ppp_ar_enabled, bool):
                self.ppp_ar_enabled = ppp_ar_enabled
        except Exception as e:
            logger.warning(f"Failed to read target_hours/ppp_tier/ppp_ar_enabled from state: {e}")
        
        # Resume from saved state
        if self.state.survey_state == SurveyState.PAUSED:
            self.state.resume_survey()
        
        # Restart survey thread
        self._running = True
        self._thread = threading.Thread(target=self._survey_loop, daemon=True)
        self._thread.start()
        
        logger.info("Survey recovered successfully")
        log_event("auto_survey", "recovered", {})
        return True
