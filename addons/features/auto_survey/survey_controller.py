"""
Auto Survey-In Controller
=========================

Main controller for 24-hour automatic survey-in process.

Orchestrates:
- RTKBase configuration auto-discovery
- GNSS data logging (enables str2str_file if needed)
- RINEX conversion from raw logs
- SPP positioning with outlier rejection
- Geoid correction
- RTKBase configuration updates
- State persistence
"""

import logging
import time
import subprocess
from pathlib import Path
from typing import Optional, Dict
from datetime import datetime, timedelta
import threading
import os

from .rtkbase_config import RTKBaseConfig
from .rinex_converter import RINEXConverter
from .spp_processor import SPPProcessor
from .position_estimator import PositionEstimator
from .geoid_corrector import GeoidCorrector
from .config_manager import ConfigManager
from .state_manager import StateManager, SurveyState

try:
    from audit_logger import log_event
except ImportError:
    log_event = lambda *a, **k: None

logger = logging.getLogger(__name__)


class SurveyController:
    """
    Auto Survey-In orchestration with RTKBase integration
    
    Features:
    - Auto-discovers RTKBase configuration
    - Enables file logging automatically
    - Converts raw logs to RINEX
    - Processes with SPP positioning
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
        self.spp = SPPProcessor()
        self.estimator = PositionEstimator(outlier_threshold=3.5, min_epochs=50)
        self.geoid = GeoidCorrector()
        self.config = ConfigManager(settings_file)
        self.state = StateManager(state_file)

        # Geoid config (upload directory + persisted config)
        self.geoid_dir = self.rtkbase.rtkbase_root / "geomaxima_geoid"
        self.geoid_dir.mkdir(parents=True, exist_ok=True)
        self.geoid_config_path = self.geoid_dir / "geoid_config.json"
        self._load_geoid_model()
        
        # Survey parameters
        self.target_hours = 24

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
    
    def start_survey(self, target_hours: int = 24) -> bool:
        """
        Start new survey session
        
        Args:
            target_hours: Survey duration in hours (default: 24)
            
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
        if not self.state.start_survey(target_hours):
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
    
    def _survey_loop(self):
        """
        Main survey loop - runs in background thread
        
        Progressive update schedule:
        - 0-6 hours: updates every 15 minutes
        - 6-24 hours: updates every 1 hour
        - At 24 hours: final update
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
        logger.info("Using RINEX conversion workflow (RTKBase raw logs → RINEX → SPP)")
        
        try:
            while self._running:
                # Stop doing work if state is not RUNNING (e.g., paused/reset from UI)
                if self.state.survey_state != SurveyState.RUNNING:
                    time.sleep(2)
                    continue

                now = datetime.utcnow()
                elapsed_hours = (now - start_time).total_seconds() / 3600

                # Hard timeout: fail if no successful update for too long
                try:
                    st = self.state.get_status()
                    last_success_raw = st.get('last_success_update_time')
                    if last_success_raw:
                        last_success = datetime.fromisoformat(last_success_raw)
                    else:
                        last_success = start_time
                    minutes_since_success = (now - last_success).total_seconds() / 60.0
                    if minutes_since_success >= float(self.update_timeout_minutes):
                        reason = st.get('last_failure_reason') or 'No successful coordinate update'
                        msg = (
                            f"No successful coordinate update for {minutes_since_success:.0f} minutes "
                            f"(timeout={self.update_timeout_minutes}): {reason}"
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
    
    def _perform_update(self, is_final: bool = False) -> bool:
        """
        Perform position update using RINEX workflow:
        1. Find latest raw GNSS log file
        2. Convert to RINEX (obs + nav)
        3. Process with rnx2rtkp for SPP
        4. Parse position solutions
        5. Estimate mean position with outlier rejection
        6. Apply geoid correction
        7. Update RTKBase configuration
        8. Save state
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
            
            # Step 3: Process SPP
            pos_file = self.spp.process_spp(obs_file, nav_file)
            
            if not pos_file:
                logger.error("SPP processing failed")
                self.state.record_update_failure("SPP processing failed (rnx2rtkp)")
                return False
            
            logger.info(f"✓ SPP position file: {pos_file.name}")
            
            # Step 4: Parse positions
            positions = self.spp.parse_position_file(pos_file)
            
            if not positions:
                logger.warning("No positions in SPP output")
                self.state.record_update_failure("No positions in SPP output")
                return False
            
            # Accept common RTKLIB quality flags.
            # Depending on configuration/data, rnx2rtkp may output different Q values.
            # 1=FIX, 2=FLOAT, 4=DGPS, 5=SINGLE
            quality_positions = [p for p in positions if p.get('Q') in (1, 2, 4, 5)]
            
            if not quality_positions:
                logger.warning(f"No SPP solutions found (total positions: {len(positions)})")
                self.state.record_update_failure("No usable solutions in SPP output (quality filter)")
                return False
            
            logger.info(f"Found {len(quality_positions)} SPP solutions")
            
            # Step 5: Estimate mean position
            estimate = self.estimator.estimate_position(quality_positions)
            
            if not estimate:
                logger.error("Failed to estimate position")
                self.state.record_update_failure("Failed to estimate position (insufficient/unstable data)")
                return False
            
            logger.info(f"Position estimate: {estimate.lat:.8f}°, {estimate.lon:.8f}°, {estimate.height:.3f}m")
            logger.info(f"Std: H={estimate.horizontal_std_meters*1000:.1f}mm, V={estimate.std_height*1000:.1f}mm")
            
            # Step 6: Apply geoid correction
            h_ortho = self.geoid.ellipsoidal_to_orthometric(
                estimate.lat,
                estimate.lon,
                estimate.height
            )
            
            if h_ortho is None:
                logger.warning("Geoid correction failed, using ellipsoidal height")
                h_ortho = estimate.height
            else:
                geoid_sep = estimate.height - h_ortho
                logger.info(f"Geoid correction: {geoid_sep:+.3f}m → Height MSL: {h_ortho:.3f}m")
            
            # Step 7: Update RTKBase configuration
            if is_final:
                logger.info("🎯 FINAL UPDATE - Applying permanent coordinates...")
            else:
                logger.info("⏱ INTERIM UPDATE - Applying temporary coordinates...")
            
            if self.rtkbase.update_position(estimate.lat, estimate.lon, h_ortho):
                if is_final:
                    logger.info("✓ Final configuration applied successfully")
                else:
                    logger.info("✓ Temporary configuration updated")

                # Restart services on every update so new coords take effect immediately
                try:
                    restart_result = self.restart_rtkbase_services()
                    if not restart_result.get('success', False):
                        logger.warning("Service restart reported failure during update")
                except Exception as restart_err:
                    logger.error(f"Service restart after update failed: {restart_err}")
            else:
                logger.error("Failed to update configuration")
                self.state.record_update_failure("Failed to update RTKBase settings.conf")
                return False
            
            # Step 8: Update state
            # Explicit float()/int() casts: estimate.* fields come from numpy
            # aggregations (np.sum/np.sqrt/np.mean) and would otherwise leak
            # numpy.float64/numpy.int64 into the JSON-serialized state.
            position = {
                'lat': float(estimate.lat),
                'lon': float(estimate.lon),
                'height': float(h_ortho)
            }

            position_std = {
                'std_lat': float(estimate.std_lat),
                'std_lon': float(estimate.std_lon),
                'std_height': float(estimate.std_height),
                'std_h_meters': float(estimate.horizontal_std_meters)
            }

            quality_metrics = {
                'mean_sats': float(estimate.mean_sats) if hasattr(estimate, 'mean_sats') else 0,
                'rejected_epochs': int(estimate.rejected_epochs) if hasattr(estimate, 'rejected_epochs') else 0,
                'is_final': is_final  # Mark if this is final or interim
            }
            
            self.state.update_progress(
                position=position,
                position_std=position_std,
                num_epochs=estimate.num_epochs,
                quality_metrics=quality_metrics
            )
            
            if is_final:
                logger.info(f"✓ FINAL UPDATE complete - Epochs: {estimate.num_epochs}, H_std: {estimate.horizontal_std_meters*1000:.1f}mm")
            else:
                logger.info(f"✓ Interim update complete - Epochs: {estimate.num_epochs}, H_std: {estimate.horizontal_std_meters*1000:.1f}mm")

            return True
            
        except Exception as e:
            logger.error(f"Update failed: {e}", exc_info=True)
            try:
                self.state.record_update_failure(f"Unhandled exception: {e}")
            except Exception:
                pass
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
        """
        try:
            logger.info("=" * 60)
            logger.info("🎯 FINALIZING SURVEY - Processing complete 24h dataset...")
            logger.info("=" * 60)
            
            # Snapshot any previously computed position so we can still complete even if final update fails
            before_status = self.state.get_status()
            before_pos = before_status.get('current_position')

            # Perform final update with all accumulated data
            self._perform_update(is_final=True)

            # Get current state
            status = self.state.get_status()
            pos = status.get('current_position') or before_pos

            if pos:
                std = status.get('position_std', {})
                
                self.state.complete_survey(pos)
                
                logger.info("=" * 60)
                logger.info("✓ SURVEY COMPLETED SUCCESSFULLY")
                logger.info(f"Final Position: {pos['lat']:.8f}°, {pos['lon']:.8f}°, {pos['height']:.3f}m")
                logger.info(f"Horizontal Accuracy: {std.get('std_h_meters', 0)*1000:.1f}mm")
                logger.info(f"Vertical Accuracy: {std.get('std_height', 0)*1000:.1f}mm")
                logger.info(f"Total Epochs: {status.get('num_epochs', 0)}")
                logger.info("=" * 60)
                
                # CRITICAL: Apply coordinates to RTKBase configuration FIRST
                try:
                    logger.info(f"✓ Applying coordinates to RTKBase: {pos['lat']:.8f} {pos['lon']:.8f} {pos['height']:.3f}")
                    if self.rtkbase.update_position(pos['lat'], pos['lon'], pos['height']):
                        logger.info("✓ RTKBase configuration updated successfully")
                        # Persist that coordinates were applied
                        self.state.mark_applied({
                            'lat': pos['lat'],
                            'lon': pos['lon'],
                            'height': pos['height']
                        })
                        
                        # CRITICAL: Wait for filesystem to stabilize (settings.conf is flushed)
                        import time
                        logger.info("Waiting 2 seconds for settings.conf to stabilize...")
                        time.sleep(2)
                        
                        # NOW restart services - settings.conf is guaranteed to be on disk
                        try:
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
                logger.error("No position available for finalization")
                self._fail("No final position computed")

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

        # Auto-apply coordinates if survey is completed but not yet applied
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

        # Ensure controller uses persisted target_hours (so loop completion matches UI)
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
        
        # Restart survey thread
        self._running = True
        self._thread = threading.Thread(target=self._survey_loop, daemon=True)
        self._thread.start()
        
        logger.info("Survey recovered successfully")
        log_event("auto_survey", "recovered", {})
        return True
