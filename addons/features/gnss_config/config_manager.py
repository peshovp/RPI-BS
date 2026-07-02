"""
GNSS Receiver Configuration Manager
Supports: ZED-F9P, Mosaic-X5, UM980/UM982
"""

import logging
import serial
import json
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from datetime import datetime

logger = logging.getLogger(__name__)


class ReceiverDetector:
    """Auto-detect GNSS receiver type and capabilities"""
    
    BAUDRATES = [9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600]
    
    RECEIVER_SIGNATURES = {
        'ZED-F9P': {
            'query': b'\xB5\x62\x0A\x04\x00\x00\x0E\x34',  # UBX-MON-VER
            'response_prefix': b'\xB5\x62\x0A\x04',
            'name_pattern': b'ZED-F9P'
        },
        'Mosaic-X5': {
            'query': b'getReceiverInfo\r\n',
            'response_prefix': b'$R,',
            'name_pattern': b'MOSAIC'
        },
        'UM980': {
            'query': b'VERSION\r\n',
            'response_prefix': b'#VERSION',
            'name_pattern': b'UM980'
        },
        'UM982': {
            'query': b'VERSION\r\n',
            'response_prefix': b'#VERSION',
            'name_pattern': b'UM982'
        }
    }
    
    @classmethod
    def detect_receiver(cls, port: str, timeout: float = 2.0) -> Optional[Dict]:
        """
        Auto-detect receiver type on given serial port
        
        Args:
            port: Serial port path (e.g., /dev/ttyACM0)
            timeout: Detection timeout per baudrate
            
        Returns:
            Dict with receiver info or None if not detected
        """
        logger.info(f"Detecting receiver on {port}...")
        
        # Check if port exists and is accessible
        import os
        if not os.path.exists(port):
            logger.warning(f"Port {port} does not exist")
            return None
        
        for baudrate in cls.BAUDRATES:
            try:
                with serial.Serial(port, baudrate, timeout=timeout) as ser:
                    # Try each receiver type
                    for receiver_type, signature in cls.RECEIVER_SIGNATURES.items():
                        logger.debug(f"Testing {receiver_type} at {baudrate} baud...")
                        
                        # Send query
                        ser.write(signature['query'])
                        time.sleep(0.5)
                        
                        # Read response
                        response = ser.read(1024)
                        
                        if signature['response_prefix'] in response and signature['name_pattern'] in response:
                            logger.info(f"✓ Detected {receiver_type} at {baudrate} baud")
                            
                            return {
                                'type': receiver_type,
                                'port': port,
                                'baudrate': baudrate,
                                'firmware': cls._parse_firmware(receiver_type, response),
                                'detected_at': datetime.now().isoformat()
                            }
                        
            except (serial.SerialException, OSError) as e:
                error_msg = str(e).lower()
                if 'permission denied' in error_msg:
                    logger.warning(f"Permission denied on {port} at {baudrate} baud - check user permissions")
                elif 'device or resource busy' in error_msg or 'resource temporarily unavailable' in error_msg:
                    logger.warning(f"Port {port} is busy (may be used by RTKBase services) - stop services first")
                else:
                    logger.debug(f"Failed at {baudrate} baud: {e}")
                continue
        
        logger.warning(f"No receiver detected on {port}")
        return None
    
    @staticmethod
    def _parse_firmware(receiver_type: str, response: bytes) -> str:
        """Extract firmware version from response"""
        try:
            if receiver_type.startswith('ZED'):
                # UBX-MON-VER response parsing
                text = response.decode('ascii', errors='ignore')
                lines = text.split('\x00')
                for line in lines:
                    if 'FWVER' in line or 'ROM' in line:
                        return line.strip()
            
            elif receiver_type.startswith('Mosaic'):
                # Septentrio response parsing
                text = response.decode('ascii', errors='ignore')
                if 'FirmwareVersion' in text:
                    return text.split('FirmwareVersion')[1].split()[0]
            
            elif receiver_type.startswith('UM'):
                # Unicore response parsing
                text = response.decode('ascii', errors='ignore')
                if '#VERSION' in text:
                    parts = text.split(',')
                    if len(parts) > 2:
                        return parts[2].strip()
            
        except Exception as e:
            logger.debug(f"Firmware parse error: {e}")
        
        return "Unknown"


class GNSSConfigManager:
    """Manage GNSS receiver configurations"""
    
    def __init__(self, config_dir: str = "/var/lib/rtkbase/gnss_configs"):
        """
        Initialize configuration manager
        
        Args:
            config_dir: Directory to store configuration profiles
        """
        self.config_dir = Path(config_dir)
        self.config_dir.mkdir(parents=True, exist_ok=True)
        
        self.detector = ReceiverDetector()
        
        logger.info(f"GNSS Config Manager initialized (config_dir: {config_dir})")
    
    def scan_ports(self) -> List[Dict]:
        """
        Scan all available serial ports for GNSS receivers
        
        Returns:
            List of detected receivers with info
        """
        import glob
        
        # Common serial port patterns
        port_patterns = [
            '/dev/ttyACM*',
            '/dev/ttyUSB*',
            '/dev/ttyS*',
            '/dev/ttyAMA*',       # Raspberry Pi serial
            '/dev/ttyGNSS*',      # Custom GNSS symlinks
            '/dev/gnss*',         # Alternative GNSS naming
            '/dev/serial/by-id/*',
            '/dev/serial/by-path/*'
        ]
        
        detected = []
        ports = []
        
        for pattern in port_patterns:
            ports.extend(glob.glob(pattern))
        
        logger.info(f"Scanning {len(ports)} serial ports...")
        
        for port in ports:
            logger.info(f"Checking port: {port}")
            try:
                result = self.detector.detect_receiver(port)
                if result:
                    logger.info(f"✓ Found {result['type']} on {port}")
                    detected.append(result)
                else:
                    logger.debug(f"No receiver detected on {port}")
            except Exception as e:
                logger.error(f"Error scanning {port}: {e}")
        
        logger.info(f"Scan complete. Found {len(detected)} receiver(s)")
        return detected
    
    def get_receiver_info(self, port: str) -> Optional[Dict]:
        """Get detailed receiver information"""
        return self.detector.detect_receiver(port)
    
    def list_profiles(self, receiver_type: Optional[str] = None) -> List[Dict]:
        """
        List saved configuration profiles
        
        Args:
            receiver_type: Filter by receiver type (optional)
            
        Returns:
            List of profile metadata
        """
        profiles = []
        
        for config_file in self.config_dir.glob('*.json'):
            try:
                with open(config_file, 'r') as f:
                    profile = json.load(f)
                
                if receiver_type is None or profile.get('receiver_type') == receiver_type:
                    profiles.append({
                        'name': config_file.stem,
                        'receiver_type': profile.get('receiver_type'),
                        'description': profile.get('description'),
                        'created_at': profile.get('created_at'),
                        'file': str(config_file)
                    })
            except Exception as e:
                logger.error(f"Failed to load profile {config_file}: {e}")
        
        return sorted(profiles, key=lambda x: x.get('created_at', ''), reverse=True)
    
    def save_profile(self, name: str, receiver_type: str, config: Dict, description: str = "") -> bool:
        """
        Save configuration profile
        
        Args:
            name: Profile name
            receiver_type: Receiver type (ZED-F9P, Mosaic-X5, UM980, etc.)
            config: Configuration data
            description: Profile description
            
        Returns:
            True if saved successfully
        """
        try:
            profile_data = {
                'name': name,
                'receiver_type': receiver_type,
                'description': description,
                'config': config,
                'created_at': datetime.now().isoformat(),
                'version': '1.0'
            }
            
            profile_file = self.config_dir / f"{name}.json"
            
            with open(profile_file, 'w') as f:
                json.dump(profile_data, f, indent=2)
            
            logger.info(f"✓ Saved profile: {name}")
            return True
            
        except Exception as e:
            logger.error(f"Failed to save profile {name}: {e}")
            return False
    
    def load_profile(self, name: str) -> Optional[Dict]:
        """Load configuration profile"""
        try:
            profile_file = self.config_dir / f"{name}.json"
            
            if not profile_file.exists():
                logger.error(f"Profile not found: {name}")
                return None
            
            with open(profile_file, 'r') as f:
                return json.load(f)
                
        except Exception as e:
            logger.error(f"Failed to load profile {name}: {e}")
            return None
    
    def delete_profile(self, name: str) -> bool:
        """Delete configuration profile"""
        try:
            profile_file = self.config_dir / f"{name}.json"
            
            if profile_file.exists():
                profile_file.unlink()
                logger.info(f"✓ Deleted profile: {name}")
                return True
            else:
                logger.warning(f"Profile not found: {name}")
                return False
                
        except Exception as e:
            logger.error(f"Failed to delete profile {name}: {e}")
            return False
    
    def export_profile(self, name: str, export_path: str) -> bool:
        """Export profile to file"""
        try:
            profile = self.load_profile(name)
            if not profile:
                return False
            
            export_file = Path(export_path)
            
            with open(export_file, 'w') as f:
                json.dump(profile, f, indent=2)
            
            logger.info(f"✓ Exported profile to: {export_path}")
            return True
            
        except Exception as e:
            logger.error(f"Failed to export profile: {e}")
            return False
    
    def import_profile(self, import_path: str) -> Optional[str]:
        """
        Import profile from file
        
        Returns:
            Profile name if successful, None otherwise
        """
        try:
            with open(import_path, 'r') as f:
                profile = json.load(f)
            
            name = profile.get('name', Path(import_path).stem)
            receiver_type = profile.get('receiver_type')
            config = profile.get('config')
            description = profile.get('description', 'Imported profile')
            
            if self.save_profile(name, receiver_type, config, description):
                logger.info(f"✓ Imported profile: {name}")
                return name
            else:
                return None
                
        except Exception as e:
            logger.error(f"Failed to import profile: {e}")
            return None
