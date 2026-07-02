"""
Unicore UM980/UM982 Configuration
ASCII protocol implementation
"""

import logging
import serial
import time
from typing import Dict, List, Optional

logger = logging.getLogger(__name__)


class UnicoreConfigurator:
    """UM980/UM982 receiver configuration via ASCII commands"""
    
    # RTCM message configuration
    RTCM_MESSAGES = {
        1005: 'RTCM1005',
        1074: 'RTCM1074',
        1077: 'RTCM1077',
        1084: 'RTCM1084',
        1087: 'RTCM1087',
        1094: 'RTCM1094',
        1097: 'RTCM1097',
        1124: 'RTCM1124',
        1127: 'RTCM1127',
        1230: 'RTCM1230'
    }
    
    def __init__(self, port: str, baudrate: int = 115200):
        """
        Initialize Unicore configurator
        
        Args:
            port: Serial port path
            baudrate: Initial baudrate
        """
        self.port = port
        self.baudrate = baudrate
        self.serial = None
    
    def connect(self) -> bool:
        """Connect to receiver"""
        try:
            self.serial = serial.Serial(
                self.port,
                self.baudrate,
                timeout=2.0,
                write_timeout=2.0
            )
            time.sleep(0.5)
            logger.info(f"✓ Connected to Unicore on {self.port}")
            return True
        except Exception as e:
            logger.error(f"Failed to connect: {e}")
            return False
    
    def disconnect(self):
        """Disconnect from receiver"""
        if self.serial and self.serial.is_open:
            self.serial.close()
            logger.info("Disconnected from Unicore")
    
    def send_command(self, command: str, wait_for_ok: bool = True) -> Optional[str]:
        """
        Send ASCII command to receiver
        
        Args:
            command: Command string
            wait_for_ok: Wait for OK response
            
        Returns:
            Response string or None
        """
        if not self.serial or not self.serial.is_open:
            return None
        
        try:
            # Send command
            self.serial.write(f"{command}\r\n".encode('ascii'))
            time.sleep(0.2)
            
            # Read response
            response = ''
            start_time = time.time()
            
            while time.time() - start_time < 2.0:
                if self.serial.in_waiting:
                    chunk = self.serial.read(self.serial.in_waiting).decode('ascii', errors='ignore')
                    response += chunk
                    
                    if wait_for_ok and ('OK' in response or 'ERROR' in response):
                        break
                time.sleep(0.1)
            
            return response.strip()
            
        except Exception as e:
            logger.error(f"Command failed: {e}")
            return None
    
    def get_version(self) -> Optional[Dict]:
        """Get receiver firmware version"""
        response = self.send_command('VERSION')
        
        if response and '#VERSION' in response:
            # Parse version response
            # Format: #VERSIONA,COM1,0,69.5,FINESTEERING,2205,336424.000,02000020,cdba,16248;
            # 28,GPSCARD,"FIRMWARE","UM980","","UM980-1.10","","2023/Mar/20","13:23:55"*4efa20d1
            
            lines = response.split('\n')
            for line in lines:
                if 'UM98' in line:
                    parts = line.split(',')
                    if len(parts) > 5:
                        return {
                            'model': parts[3].strip('"'),
                            'firmware': parts[5].strip('"'),
                            'build_date': parts[7].strip('"') if len(parts) > 7 else 'Unknown'
                        }
        
        return None
    
    def set_rtcm_messages(self, messages: List[int], port: str = 'COM1', rate: float = 1.0) -> bool:
        """
        Configure RTCM3 message output
        
        Args:
            messages: List of RTCM message types
            port: Output port (COM1, COM2, COM3)
            rate: Output rate in seconds
            
        Returns:
            True if successful
        """
        if not self.serial or not self.serial.is_open:
            return False
        
        try:
            success_count = 0
            
            for msg_type in messages:
                if msg_type not in self.RTCM_MESSAGES:
                    logger.warning(f"Unsupported RTCM message: {msg_type}")
                    continue
                
                msg_name = self.RTCM_MESSAGES[msg_type]
                
                # Command format: RTCMMSG COM1 msg_name rate
                cmd = f'RTCMMSG {port} {msg_name} {rate}'
                response = self.send_command(cmd)
                
                if response and 'OK' in response:
                    logger.info(f"✓ Enabled {msg_name} on {port} at {rate}s")
                    success_count += 1
                else:
                    logger.error(f"Failed to enable {msg_name}: {response}")
            
            return success_count == len(messages)
            
        except Exception as e:
            logger.error(f"Set RTCM messages failed: {e}")
            return False
    
    def set_base_mode(self, mode: str, **kwargs) -> bool:
        """
        Configure base station mode
        
        Args:
            mode: 'auto' or 'fixed'
            **kwargs: Mode-specific parameters
                For auto: duration (seconds)
                For fixed: lat, lon, height
                
        Returns:
            True if successful
        """
        if not self.serial or not self.serial.is_open:
            return False
        
        try:
            if mode == 'auto':
                duration = kwargs.get('duration', 300)
                
                # Enable base mode with auto-survey
                cmd = f'MODE BASE TIME {duration}'
                response = self.send_command(cmd)
                
                if response and 'OK' in response:
                    logger.info(f"✓ Base mode: auto-survey {duration}s")
                    return True
                    
            elif mode == 'fixed':
                lat = kwargs.get('lat')
                lon = kwargs.get('lon')
                height = kwargs.get('height')
                
                if lat is None or lon is None or height is None:
                    logger.error("Fixed mode requires lat, lon, height")
                    return False
                
                # Set fixed base position
                # Format: MODE BASE lat lon height
                cmd = f'MODE BASE {lat} {lon} {height}'
                response = self.send_command(cmd)
                
                if response and 'OK' in response:
                    logger.info(f"✓ Base mode: fixed {lat}, {lon}, {height}")
                    return True
            else:
                logger.error(f"Unknown mode: {mode}")
                return False
            
            logger.error(f"Set base mode failed: {response}")
            return False
            
        except Exception as e:
            logger.error(f"Set base mode failed: {e}")
            return False
    
    def set_gnss_systems(self, systems: List[str]) -> bool:
        """
        Configure GNSS systems
        
        Args:
            systems: List of systems ('GPS', 'GLONASS', 'GALILEO', 'BEIDOU', 'QZSS')
        """
        # Convert to config command
        config_value = 0
        system_bits = {
            'GPS': 1,
            'GLONASS': 2,
            'GALILEO': 8,
            'BEIDOU': 4,
            'QZSS': 16
        }
        
        for system in systems:
            if system.upper() in system_bits:
                config_value |= system_bits[system.upper()]
        
        cmd = f'CONFIG SIGNALGROUP {config_value}'
        response = self.send_command(cmd)
        
        if response and 'OK' in response:
            logger.info(f"✓ GNSS systems: {', '.join(systems)}")
            return True
        else:
            logger.error(f"Failed to set GNSS systems: {response}")
            return False
    
    def set_elevation_mask(self, angle: int = 10) -> bool:
        """Set elevation mask angle (degrees)"""
        cmd = f'ECUTOFF {angle}'
        response = self.send_command(cmd)
        
        if response and 'OK' in response:
            logger.info(f"✓ Elevation mask: {angle}°")
            return True
        return False
    
    def save_config(self) -> bool:
        """Save configuration to flash"""
        response = self.send_command('SAVECONFIG')
        
        if response and 'OK' in response:
            logger.info("✓ Configuration saved to flash")
            return True
        else:
            logger.error(f"Save config failed: {response}")
            return False
    
    def reset_receiver(self, reset_type: str = 'hot') -> bool:
        """
        Reset receiver
        
        Args:
            reset_type: 'hot', 'warm', 'cold'
        """
        reset_commands = {
            'hot': 'RESET HOTRESET',
            'warm': 'RESET WARMRESET',
            'cold': 'RESET COLDRESET'
        }
        
        cmd = reset_commands.get(reset_type)
        if not cmd:
            logger.error(f"Unknown reset type: {reset_type}")
            return False
        
        try:
            self.send_command(cmd, wait_for_ok=False)
            logger.info(f"✓ Receiver reset ({reset_type})")
            return True
        except Exception as e:
            logger.error(f"Reset failed: {e}")
            return False
    
    def get_current_config(self) -> Dict:
        """Get current receiver configuration"""
        config = {}
        
        # Get position mode
        response = self.send_command('MODE')
        if response:
            config['mode'] = response
        
        # Get RTCM messages
        response = self.send_command('RTCMMSG')
        if response:
            config['rtcm_messages'] = response
        
        # Get GNSS systems
        response = self.send_command('CONFIG SIGNALGROUP')
        if response:
            config['gnss_systems'] = response
        
        return config
