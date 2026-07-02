"""
RTKBase Configuration Manager
=============================

Safe management of RTKBase settings.conf for base station coordinates.

Handles coordinate updates without disrupting other configuration parameters.
"""

import logging
from pathlib import Path
from typing import Optional, Dict, Tuple
import configparser
import shutil
from datetime import datetime

logger = logging.getLogger(__name__)


class ConfigManager:
    """
    Safe RTKBase settings.conf management
    
    Updates antenna position while preserving all other settings.
    """
    
    def __init__(self, settings_path: str = "/home/peshovp/rtkbase/settings.conf"):
        """
        Args:
            settings_path: Path to RTKBase settings.conf
        """
        self.settings_path = Path(settings_path)
        
        if not self.settings_path.exists():
            raise FileNotFoundError(f"Settings file not found: {settings_path}")
        
        self.config = configparser.ConfigParser()
        self.config.read(self.settings_path)
    
    def get_current_position(self) -> Optional[Dict[str, float]]:
        """
        Get current antenna position from settings.conf
        
        Returns:
            Dict with lat, lon, height (orthometric) or None if not set
        """
        try:
            # RTKBase stores position in [main] section
            if 'main' not in self.config:
                logger.warning("No [main] section in settings.conf")
                return None
            
            main = self.config['main']
            
            # Check if position is set
            if 'ant_lat' not in main or 'ant_lon' not in main or 'ant_height' not in main:
                logger.info("Antenna position not configured")
                return None
            
            lat = float(main['ant_lat'])
            lon = float(main['ant_lon'])
            height = float(main['ant_height'])
            
            return {
                'lat': lat,
                'lon': lon,
                'height': height
            }
            
        except Exception as e:
            logger.error(f"Failed to read position: {e}")
            return None
    
    def set_antenna_position(self, 
                            lat: float, 
                            lon: float, 
                            height: float,
                            backup: bool = True) -> bool:
        """
        Update antenna position in settings.conf
        
        Args:
            lat: Latitude in decimal degrees
            lon: Longitude in decimal degrees
            height: Orthometric height (MSL) in meters
            backup: Create backup before modifying (default: True)
            
        Returns:
            True if updated successfully
        """
        try:
            # Create backup
            if backup:
                backup_path = self._create_backup()
                logger.info(f"Created backup: {backup_path}")
            
            # Reload config to ensure fresh state
            self.config.read(self.settings_path)
            
            # Ensure [main] section exists
            if 'main' not in self.config:
                self.config.add_section('main')
            
            # Update position fields
            self.config['main']['ant_lat'] = f"{lat:.8f}"
            self.config['main']['ant_lon'] = f"{lon:.8f}"
            self.config['main']['ant_height'] = f"{height:.3f}"
            
            # Update position type (0=LLH, 1=XYZ)
            self.config['main']['ant_pos_type'] = "0"
            
            # Write to file
            with open(self.settings_path, 'w') as f:
                self.config.write(f)
            
            logger.info(f"Updated antenna position: {lat:.8f}°, {lon:.8f}°, {height:.3f}m")
            return True
            
        except Exception as e:
            logger.error(f"Failed to update position: {e}")
            return False
    
    def _create_backup(self) -> Path:
        """
        Create timestamped backup of settings.conf
        
        Returns:
            Path to backup file
        """
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        backup_dir = self.settings_path.parent / "backups"
        backup_dir.mkdir(exist_ok=True)
        
        backup_path = backup_dir / f"settings.conf.{timestamp}"
        shutil.copy2(self.settings_path, backup_path)
        
        # Keep only last 10 backups
        self._cleanup_old_backups(backup_dir, keep=10)
        
        return backup_path
    
    def _cleanup_old_backups(self, backup_dir: Path, keep: int = 10):
        """Remove old backup files, keeping only the most recent"""
        backups = sorted(backup_dir.glob("settings.conf.*"))
        
        if len(backups) > keep:
            for old_backup in backups[:-keep]:
                old_backup.unlink()
                logger.debug(f"Removed old backup: {old_backup}")
    
    def get_receiver_config(self) -> Dict[str, str]:
        """
        Get GNSS receiver configuration
        
        Returns:
            Dict with receiver type, port, format, etc.
        """
        try:
            if 'main' not in self.config:
                return {}
            
            main = self.config['main']
            
            return {
                'receiver_type': main.get('receiver', 'unknown'),
                'com_port': main.get('com_port', 'unknown'),
                'com_port_settings': main.get('com_port_settings', ''),
                'receiver_format': main.get('receiver_format', 'ubx')
            }
            
        except Exception as e:
            logger.error(f"Failed to read receiver config: {e}")
            return {}
    
    def get_str2str_mode(self) -> str:
        """
        Get current str2str operating mode
        
        Returns:
            Mode string ('single', 'base_rover', 'off', etc.)
        """
        try:
            if 'main' not in self.config:
                return 'unknown'
            
            return self.config['main'].get('position_mode', 'unknown')
            
        except Exception:
            return 'unknown'
    
    def validate_position(self, lat: float, lon: float, height: float) -> Tuple[bool, str]:
        """
        Validate position values before updating
        
        Args:
            lat: Latitude in degrees
            lon: Longitude in degrees
            height: Height in meters
            
        Returns:
            Tuple of (is_valid, error_message)
        """
        # Check latitude range
        if lat < -90 or lat > 90:
            return False, f"Invalid latitude: {lat} (must be -90 to 90)"
        
        # Check longitude range
        if lon < -180 or lon > 180:
            return False, f"Invalid longitude: {lon} (must be -180 to 180)"
        
        # Check height range (reasonable limits)
        if height < -500 or height > 9000:
            return False, f"Invalid height: {height}m (must be -500 to 9000)"
        
        # Warn if position is at null island (0, 0)
        if abs(lat) < 0.001 and abs(lon) < 0.001:
            return False, "Position at (0, 0) - likely invalid"
        
        return True, ""
