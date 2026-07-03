"""
Survey State Manager
===================

Persistent state management for Auto Survey-In process.

Handles state persistence across restarts, ensuring survey can recover from
system reboots or crashes without losing progress.
"""

import logging
import json
import numpy as np
from pathlib import Path
from typing import Optional, Dict, Any
from datetime import datetime
import os
from enum import Enum

logger = logging.getLogger(__name__)


class SurveyState(Enum):
    """Survey process states"""
    IDLE = "idle"
    RUNNING = "running"
    PAUSED = "paused"
    COMPLETED = "completed"
    FAILED = "failed"


class StateManager:
    """
    State persistence for Auto Survey-In
    
    Stores survey progress to JSON file for recovery after restarts.
    """
    
    def __init__(self, state_file: str = "/var/lib/rtkbase/survey_state.json"):
        """
        Args:
            state_file: Path to state persistence file
        """
        self.state_file = Path(state_file)

        self.state_file.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        
        self._state: Dict[str, Any] = self._load_state()
    
    def _load_state(self) -> Dict[str, Any]:
        """Load state from disk or return default state"""
        if not self.state_file.exists():
            logger.info("No existing state file, starting fresh")
            return self._default_state()
        
        try:
            with open(self.state_file, 'r') as f:
                state = json.load(f)
            
            # Validate required fields
            required = ['survey_state', 'start_time', 'target_hours']
            if not all(k in state for k in required):
                logger.warning("Invalid state file, using defaults")
                return self._default_state()

            # Backfill newer fields when upgrading
            if 'applied' not in state:
                state['applied'] = False
            if 'applied_time' not in state:
                state['applied_time'] = None
            if 'applied_position' not in state:
                state['applied_position'] = None

            # Update success/failure tracking
            if 'last_success_update_time' not in state:
                state['last_success_update_time'] = None
            if 'last_failure_time' not in state:
                state['last_failure_time'] = None
            if 'last_failure_reason' not in state:
                state['last_failure_reason'] = None
            if 'consecutive_failures' not in state:
                state['consecutive_failures'] = 0
            
            logger.info(f"Loaded state: {state['survey_state']} since {state['start_time']}")
            return state
            
        except Exception as e:
            logger.error(f"Failed to load state: {e}, using defaults")
            return self._default_state()
    
    def _default_state(self) -> Dict[str, Any]:
        """Return default initial state"""
        return {
            'survey_state': SurveyState.IDLE.value,
            'start_time': None,
            'end_time': None,
            'target_hours': 24,
            'completed_hours': 0,
            'num_epochs': 0,
            'num_updates': 0,
            'last_update_time': None,
            'current_position': None,  # dict with lat, lon, height
            'position_std': None,  # dict with std_lat, std_lon, std_height
            'quality_metrics': {},  # mean_ratio, mean_sats, fix_ratio
            'errors': [],
            # Tracks whether final coordinates have been applied to RTKBase
            'applied': False,
            'applied_time': None,
            'applied_position': None,
            # Update success/failure tracking
            'last_success_update_time': None,
            'last_failure_time': None,
            'last_failure_reason': None,
            'consecutive_failures': 0,
        }
    
    def _convert_numpy(self, obj):
        """Recursively convert numpy types to Python natives for JSON serialization"""
        if isinstance(obj, dict):
            return {k: self._convert_numpy(v) for k, v in obj.items()}
        elif isinstance(obj, list):
            return [self._convert_numpy(item) for item in obj]
        elif isinstance(obj, np.integer):
            return int(obj)
        elif isinstance(obj, np.floating):
            return float(obj)
        elif isinstance(obj, np.ndarray):
            return obj.tolist()
        else:
            return obj
    
    def save_state(self) -> bool:
        """
        Save current state to disk
        
        Returns:
            True if saved successfully
        """
        try:
            # Convert numpy types before saving
            state_converted = self._convert_numpy(self._state)
            
            with open(self.state_file, 'w') as f:
                json.dump(state_converted, f, indent=2)
            
            # Set explicit permissions: owner read/write only (0o600)
            os.chmod(self.state_file, 0o600)
            
            return True
        except Exception as e:
            logger.error(f"Failed to save state: {e}")
            return False

    def mark_applied(self, position: Optional[Dict[str, Any]] = None):
        """Mark that final coordinates were applied to RTKBase"""
        self._state['applied'] = True
        self._state['applied_time'] = datetime.utcnow().isoformat()
        if position:
            self._state['applied_position'] = position
        self.save_state()
    
    @property
    def survey_state(self) -> SurveyState:
        """Get current survey state"""
        return SurveyState(self._state['survey_state'])
    
    @survey_state.setter
    def survey_state(self, value: SurveyState):
        """Set survey state"""
        self._state['survey_state'] = value.value
        self.save_state()
    
    def start_survey(self, target_hours: int = 24) -> bool:
        """
        Start new survey session
        
        Args:
            target_hours: Survey duration in hours (default: 24)
            
        Returns:
            True if started successfully
        """
        if self.survey_state == SurveyState.RUNNING:
            logger.warning("Survey already running")
            return False
        
        self._state.update({
            'survey_state': SurveyState.RUNNING.value,
            'start_time': datetime.utcnow().isoformat(),
            'end_time': None,
            'target_hours': target_hours,
            'completed_hours': 0,
            'num_epochs': 0,
            'num_updates': 0,
            'last_update_time': None,
            'current_position': None,
            'position_std': None,
            'quality_metrics': {},
            'errors': [],
            # Reset apply-tracking for a fresh run
            'applied': False,
            'applied_time': None,
            'applied_position': None,
        })
        
        logger.info(f"Started {target_hours}-hour survey")
        return self.save_state()
    
    def update_progress(self, 
                       position: Dict[str, float],
                       position_std: Dict[str, float],
                       num_epochs: int,
                       quality_metrics: Dict[str, float]) -> bool:
        """
        Update survey progress
        
        Args:
            position: dict with lat, lon, height
            position_std: dict with std_lat, std_lon, std_height
            num_epochs: Total epochs processed
            quality_metrics: dict with mean_ratio, mean_sats, etc.
            
        Returns:
            True if updated successfully
        """
        if self.survey_state != SurveyState.RUNNING:
            logger.warning("Cannot update: survey not running")
            return False
        
        now = datetime.utcnow()
        start_time = datetime.fromisoformat(self._state['start_time'])
        elapsed_hours = (now - start_time).total_seconds() / 3600
        
        self._state.update({
            'completed_hours': elapsed_hours,
            'num_epochs': num_epochs,
            'num_updates': self._state['num_updates'] + 1,
            'last_update_time': now.isoformat(),
            'last_success_update_time': now.isoformat(),
            'last_failure_time': None,
            'last_failure_reason': None,
            'consecutive_failures': 0,
            'current_position': position,
            'position_std': position_std,
            'quality_metrics': quality_metrics
        })
        
        logger.info(f"Survey progress: {elapsed_hours:.1f}/{self._state['target_hours']}h, {num_epochs} epochs")
        return self.save_state()

    def record_update_failure(self, reason: str) -> bool:
        """Record a failed attempt to compute/apply coordinates."""
        now = datetime.utcnow().isoformat()
        self._state['last_failure_time'] = now
        self._state['last_failure_reason'] = str(reason)[:500]
        self._state['consecutive_failures'] = int(self._state.get('consecutive_failures', 0) or 0) + 1
        return self.save_state()
    
    def complete_survey(self, final_position: Dict[str, float]) -> bool:
        """
        Mark survey as completed
        
        Args:
            final_position: dict with lat, lon, height (orthometric)
            
        Returns:
            True if completed successfully
        """
        # Allow completion from PAUSED as well (e.g. user pauses right at the end)
        if self.survey_state not in (SurveyState.RUNNING, SurveyState.PAUSED):
            logger.warning("Cannot complete: survey not running/paused")
            return False
        
        self._state.update({
            'survey_state': SurveyState.COMPLETED.value,
            'end_time': datetime.utcnow().isoformat(),
            'final_position': final_position,  # Store final position separately
            'current_position': final_position  # Also keep in current for backward compatibility
        })
        
        logger.info(f"Survey completed: {final_position}")
        return self.save_state()
    
    def fail_survey(self, error_msg: str) -> bool:
        """
        Mark survey as failed
        
        Args:
            error_msg: Error description
            
        Returns:
            True if updated successfully
        """
        self._state['survey_state'] = SurveyState.FAILED.value
        self._state['errors'].append({
            'timestamp': datetime.utcnow().isoformat(),
            'message': error_msg
        })
        
        logger.error(f"Survey failed: {error_msg}")
        return self.save_state()
    
    def pause_survey(self) -> bool:
        """Pause running survey"""
        if self.survey_state != SurveyState.RUNNING:
            return False
        
        self.survey_state = SurveyState.PAUSED
        logger.info("Survey paused")
        return True
    
    def resume_survey(self) -> bool:
        """Resume paused survey"""
        if self.survey_state != SurveyState.PAUSED:
            return False
        
        self.survey_state = SurveyState.RUNNING
        logger.info("Survey resumed")
        return True
    
    def reset_survey(self) -> bool:
        """Reset to idle state (clear all data)"""
        self._state = self._default_state()
        logger.info("Survey reset to idle")
        return self.save_state()
    
    def get_status(self) -> Dict[str, Any]:
        """
        Get current survey status
        
        Returns:
            Dict with all state information
        """
        status = self._state.copy()
        
        # Add computed fields
        if status['start_time']:
            start = datetime.fromisoformat(status['start_time'])
            now = datetime.utcnow()
            elapsed_seconds = (now - start).total_seconds()
            
            status['elapsed_seconds'] = elapsed_seconds
            status['progress_percent'] = min(100, (elapsed_seconds / 3600 / status['target_hours']) * 100)
            
            if status['survey_state'] == SurveyState.RUNNING.value:
                remaining_seconds = max(0, status['target_hours'] * 3600 - elapsed_seconds)
                status['remaining_seconds'] = remaining_seconds
        
        return status
    
    def can_recover(self) -> bool:
        """
        Check if survey can be recovered after restart
        
        Returns:
            True if survey was running/paused and can be resumed
        """
        if self.survey_state in [SurveyState.RUNNING, SurveyState.PAUSED]:
            if self._state['start_time']:
                start = datetime.fromisoformat(self._state['start_time'])
                now = datetime.utcnow()
                elapsed_hours = (now - start).total_seconds() / 3600
                
                # Can recover if within target duration + 1 hour grace period
                return elapsed_hours < (self._state['target_hours'] + 1)
        
        return False

