"""
RTKBase Configuration Parser
============================

Auto-discovery and parsing of RTKBase settings.conf
"""

import configparser
import logging
import os
from pathlib import Path
from typing import Optional, Dict, Tuple

logger = logging.getLogger(__name__)


class RTKBaseConfig:
    """Parse and provide RTKBase configuration"""
    
    def __init__(self, settings_file: str = None):
        """
        Args:
            settings_file: Path to RTKBase settings.conf
        """
        if settings_file is None:
            # Resolve rtkbase root the same way web_app/server.py does: relative
            # to this file's location, not $HOME (this may run as root via systemd).
            _rtkbase_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../"))
            settings_file = os.path.join(_rtkbase_root, "settings.conf")
        self.settings_file = Path(settings_file)
        self.config = configparser.ConfigParser()
        
        if not self.settings_file.exists():
            raise FileNotFoundError(f"RTKBase settings not found: {settings_file}")
        
        self.config.read(self.settings_file)
        self._discover_paths()
    
    def _discover_paths(self):
        """Auto-discover RTKBase directory structure"""
        # RTKBase root is parent of settings.conf
        self.rtkbase_root = self.settings_file.parent
        
        # Standard RTKBase paths
        self.logs_dir = self.rtkbase_root / "logs"
        self.data_dir = self.rtkbase_root / "data"
        self.archives_dir = self.rtkbase_root / "archives"
        
        logger.info(f"RTKBase root: {self.rtkbase_root}")
        logger.info(f"Logs dir: {self.logs_dir}")
    
    def get_position(self) -> Optional[Tuple[float, float, float]]:
        """
        Get current configured position (lat, lon, height)
        
        Returns:
            (lat, lon, height) tuple or None
        """
        try:
            pos_str = self.config.get('main', 'position', fallback=None)
            if not pos_str:
                return None
            
            # Format: 'lat lon height' or 'lat,lon,height'
            pos_str = pos_str.strip("'\"")
            parts = pos_str.replace(',', ' ').split()
            
            if len(parts) >= 3:
                lat = float(parts[0])
                lon = float(parts[1])
                height = float(parts[2])
                return (lat, lon, height)
        except Exception as e:
            logger.warning(f"Failed to parse position: {e}")
        
        return None
    
    def get_receiver_info(self) -> Dict[str, str]:
        """Get receiver information"""
        return {
            'model': self.config.get('main', 'receiver', fallback='Unknown'),
            'format': self.config.get('main', 'receiver_format', fallback='ubx'),
            'firmware': self.config.get('main', 'receiver_firmware', fallback=''),
            'antenna': self.config.get('main', 'antenna_info', fallback=''),
        }
    
    def get_com_port(self) -> Tuple[str, str]:
        """
        Get COM port and settings
        
        Returns:
            (port, settings) e.g. ('ttyGNSS', '115200:8:n:1')
        """
        port = self.config.get('main', 'com_port', fallback='ttyACM0')
        settings = self.config.get('main', 'com_port_settings', fallback='115200:8:n:1')
        return (port, settings)
    
    def find_latest_log(self, pattern: str = "str2str_*.log") -> Optional[Path]:
        """
        Find the most recent log file matching pattern
        
        Args:
            pattern: Glob pattern for log files
            
        Returns:
            Path to latest log or None
        """
        if not self.logs_dir.exists():
            logger.warning(f"Logs directory not found: {self.logs_dir}")
            return None
        
        log_files = list(self.logs_dir.glob(pattern))
        
        if not log_files:
            logger.warning(f"No logs matching '{pattern}' in {self.logs_dir}")
            return None
        
        # Sort by modification time, newest first
        latest = max(log_files, key=lambda p: p.stat().st_mtime)
        logger.info(f"Latest log: {latest}")
        return latest
    
    def get_data_file(self) -> Optional[Path]:
        """
        Get the current GNSS data file being written
        
        Checks in order:
        1. data/ directory for active files
        2. logs/ directory for str2str_file logs
        3. Latest str2str_tcp log
        
        Returns:
            Path to data file or None
        """
        # Check data directory first
        if self.data_dir.exists():
            data_files = list(self.data_dir.glob("*.ubx")) + \
                        list(self.data_dir.glob("*.rtcm3"))
            if data_files:
                latest = max(data_files, key=lambda p: p.stat().st_mtime)
                return latest
        
        # Check for file service logs
        file_log = self.find_latest_log("str2str_file_*.log")
        if file_log:
            return file_log
        
        # Fallback to TCP log (may contain data)
        tcp_log = self.find_latest_log("str2str_tcp_*.log")
        return tcp_log
    
    def update_position(self, lat: float, lon: float, height: float) -> bool:
        """
        Update position in settings.conf
        
        CRITICAL: RTKBase expects position format with single quotes:
        position = '42.68045168 26.30807124 104.425'
        
        ConfigParser.write() removes the quotes, so we do direct file editing!
        
        Args:
            lat: Latitude (degrees)
            lon: Longitude (degrees)
            height: Height (meters, WGS84 ellipsoidal - NOT MSL/orthometric.
                    This value is embedded into RTCM 1005/1006 via str2str -p,
                    which requires ellipsoidal height for correct ARP coordinates.)
            
        Returns:
            True if updated successfully
        """
        try:
            logger.info("=" * 70)
            logger.info("UPDATE_POSITION CALLED")
            logger.info(f"  Input: lat={lat:.8f}, lon={lon:.8f}, height={height:.3f}")
            logger.info(f"  Settings file: {self.settings_file}")
            
            # Format position string exactly as RTKBase expects
            position_value = f"{lat:.8f} {lon:.8f} {height:.3f}"
            logger.info(f"  Formatted value: '{position_value}'")
            
            # Check file exists and is writable
            import os
            if not os.path.exists(self.settings_file):
                logger.error(f"  ✗ Settings file does not exist!")
                return False
            
            if not os.access(self.settings_file, os.W_OK):
                logger.error(f"  ✗ Settings file is not writable!")
                return False
            
            logger.info(f"  ✓ File exists and is writable")
            
            # Read entire file
            logger.info(f"  Reading file...")
            with open(self.settings_file, 'r') as f:
                lines = f.readlines()
            logger.info(f"  ✓ Read {len(lines)} lines")
            
            # Find position line
            logger.info(f"  Searching for 'position' line...")
            updated = False
            old_value = None
            for i, line in enumerate(lines):
                if line.strip().startswith('position'):
                    old_value = line.strip()
                    logger.info(f"  Found at line {i+1}: {old_value}")
                    # Replace with proper RTKBase format (with single quotes)
                    lines[i] = f"position = '{position_value}'\n"
                    updated = True
                    logger.info(f"  New line: {lines[i].strip()}")
                    break
            
            if not updated:
                logger.warning("  position= line not found; inserting into [main] section")
                # Try to find [main] section boundaries
                main_start = None
                main_end = None
                for i, line in enumerate(lines):
                    if line.strip().lower() == '[main]':
                        main_start = i
                        # find next section start
                        for j in range(i+1, len(lines)):
                            if lines[j].strip().startswith('[') and lines[j].strip().endswith(']'):
                                main_end = j
                                break
                        break
                insert_line = f"position = '{position_value}'\n"
                if main_start is not None:
                    # Insert before next section or at end
                    insert_index = main_end if main_end is not None else len(lines)
                    lines.insert(insert_index, insert_line)
                    logger.info(f"  Inserted position at line {insert_index+1} within [main]")
                else:
                    # No [main] section; create one at top
                    lines = ["[main]\n", insert_line] + lines
                    logger.info("  Created [main] section and inserted position at file start")
            
            # Write back entire file
            logger.info(f"  Writing updated file...")
            with open(self.settings_file, 'w') as f:
                f.writelines(lines)
                # CRITICAL: Force flush to disk before any service restart
                f.flush()
                import os
                os.fsync(f.fileno())
            logger.info(f"  ✓ File written and flushed to disk")
            
            # Verify the change
            logger.info(f"  Verifying change...")
            with open(self.settings_file, 'r') as f:
                for line in f:
                    if line.strip().startswith('position'):
                        logger.info(f"  Verified: {line.strip()}")
                        if position_value in line:
                            logger.info(f"  ✓ VERIFICATION PASSED - coordinates updated!")
                        else:
                            logger.error(f"  ✗ VERIFICATION FAILED - coordinates NOT updated!")
                            logger.error(f"    Expected: '{position_value}'")
                            logger.error(f"    Found: {line.strip()}")
                            return False
                        break
            
            # Reload config to ensure we have latest values
            self.config.read(self.settings_file)
            
            # Touch file to trigger RTKBase inotify reload
            import os
            os.utime(self.settings_file, None)
            logger.info(f"  ✓ File touched for inotify")
            
            logger.info("=" * 70)
            logger.info("✓ UPDATE_POSITION COMPLETED SUCCESSFULLY")
            logger.info(f"  Old: {old_value}")
            logger.info(f"  New: position = '{position_value}'")
            logger.info("=" * 70)
            
            return True
            
        except Exception as e:
            logger.error(f"✗ UPDATE_POSITION FAILED: {e}")
            import traceback
            logger.error(traceback.format_exc())
            return False
