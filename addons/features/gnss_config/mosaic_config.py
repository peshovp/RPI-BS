"""
Septentrio Mosaic-X5 Configuration
NMEA/SBF protocol implementation
"""

import logging
import serial
import time
from typing import Dict, List, Optional

logger = logging.getLogger(__name__)


class MosaicX5Configurator:
    """Mosaic-X5 receiver configuration via ASCII commands"""
    
    def __init__(self, port: str, baudrate: int = 115200):
        """
        Initialize Mosaic-X5 configurator
        
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
            logger.info(f"✓ Connected to Mosaic-X5 on {self.port}")
            return True
        except Exception as e:
            logger.error(f"Failed to connect: {e}")
            return False
    
    def disconnect(self):
        """Disconnect from receiver"""
        if self.serial and self.serial.is_open:
            self.serial.close()
            logger.info("Disconnected from Mosaic-X5")
    
    def send_command(self, command: str) -> Optional[str]:
        """
        Send ASCII command to receiver
        
        Args:
            command: Command string (without \r\n)
            
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
            response = self.serial.read(2048).decode('ascii', errors='ignore')
            return response.strip()
            
        except Exception as e:
            logger.error(f"Command failed: {e}")
            return None
    
    def get_version(self) -> Optional[Dict]:
        """Get receiver firmware version"""
        response = self.send_command('getReceiverInfo')
        
        if response and 'FirmwareVersion' in response:
            lines = response.split('\n')
            info = {}
            
            for line in lines:
                if ':' in line:
                    key, value = line.split(':', 1)
                    info[key.strip()] = value.strip()
            
            return {
                'firmware': info.get('FirmwareVersion', 'Unknown'),
                'hardware': info.get('ProductName', 'Mosaic-X5'),
                'serial': info.get('SerialNumber', 'Unknown')
            }
        
        return None
    
    def set_rtcm_messages(self, messages: List[int], rate: float = 1.0) -> bool:
        """
        Configure RTCM3 message output
        
        Args:
            messages: List of RTCM message types
            rate: Output rate in Hz
            
        Returns:
            True if successful
        """
        if not self.serial or not self.serial.is_open:
            return False
        
        try:
            # Disable all RTCM first
            self.send_command('setSBFOutput, Stream1, , none')
            
            # Build message list
            msg_list = '+'.join([f'RTCM{msg}' for msg in messages])
            
            # Enable selected messages on COM1
            cmd = f'setSBFOutput, Stream1, COM1, {msg_list}, sec{rate}'
            response = self.send_command(cmd)
            
            if response and '$R' in response:
                logger.info(f"✓ Enabled RTCM messages: {messages} at {rate}Hz")
                return True
            else:
                logger.error(f"Failed to set RTCM messages: {response}")
                return False
                
        except Exception as e:
            logger.error(f"Set RTCM messages failed: {e}")
            return False
    
    def set_base_mode(self, mode: str, **kwargs) -> bool:
        """
        Configure base station mode
        
        Args:
            mode: 'auto-survey' or 'fixed'
            **kwargs: Mode-specific parameters
                For auto-survey: duration (minutes), accuracy (meters)
                For fixed: lat, lon, height
                
        Returns:
            True if successful
        """
        if not self.serial or not self.serial.is_open:
            return False
        
        try:
            if mode == 'auto-survey':
                duration = kwargs.get('duration', 60)
                accuracy = kwargs.get('accuracy', 2.0)
                
                # Enable auto-survey mode
                cmd = f'setStaticPosInit, AutoSurvey, {duration}, {accuracy}'
                response = self.send_command(cmd)
                
                if response and '$R' in response:
                    logger.info(f"✓ Auto-survey: {duration}min, {accuracy}m accuracy")
                    return True
                    
            elif mode == 'fixed':
                lat = kwargs.get('lat')
                lon = kwargs.get('lon')
                height = kwargs.get('height')
                
                if lat is None or lon is None or height is None:
                    logger.error("Fixed mode requires lat, lon, height")
                    return False
                
                # Set fixed position
                cmd = f'setStaticPosInit, Manual, {lat}, {lon}, {height}'
                response = self.send_command(cmd)
                
                if response and '$R' in response:
                    logger.info(f"✓ Fixed position: {lat}, {lon}, {height}")
                    return True
            else:
                logger.error(f"Unknown mode: {mode}")
                return False
            
            logger.error(f"Set base mode failed: {response}")
            return False
            
        except Exception as e:
            logger.error(f"Set base mode failed: {e}")
            return False
    
    def set_antenna_type(self, antenna: str) -> bool:
        """
        Set antenna type
        
        Args:
            antenna: Antenna model (e.g., 'AS-ANT2BCAL')
        """
        response = self.send_command(f'setAntennaType, {antenna}')
        
        if response and '$R' in response:
            logger.info(f"✓ Antenna type: {antenna}")
            return True
        else:
            logger.error(f"Failed to set antenna: {response}")
            return False
    
    def set_elevation_mask(self, angle: int = 10) -> bool:
        """Set elevation mask angle (degrees)"""
        response = self.send_command(f'setElevationMask, {angle}')
        
        if response and '$R' in response:
            logger.info(f"✓ Elevation mask: {angle}°")
            return True
        return False
    
    def save_config(self) -> bool:
        """Save configuration to flash"""
        response = self.send_command('eccf, Current, Boot')
        
        if response and '$R' in response:
            logger.info("✓ Configuration saved to flash")
            return True
        else:
            logger.error(f"Save config failed: {response}")
            return False
    
    def reset_receiver(self, reset_type: str = 'soft') -> bool:
        """
        Reset receiver
        
        Args:
            reset_type: 'soft' (warm start) or 'hard' (factory reset)
        """
        try:
            if reset_type == 'soft':
                response = self.send_command('exeResetReceiver, soft')
            elif reset_type == 'hard':
                response = self.send_command('exeResetReceiver, hard')
            else:
                logger.error(f"Unknown reset type: {reset_type}")
                return False
            
            logger.info(f"✓ Receiver reset ({reset_type})")
            return True
        except Exception as e:
            logger.error(f"Reset failed: {e}")
            return False
    
    def get_current_config(self) -> Dict:
        """Get current receiver configuration"""
        config = {}
        
        # Get various settings
        commands = {
            'antenna': 'getAntennaType',
            'elevation_mask': 'getElevationMask',
            'sbf_output': 'getSBFOutput, Stream1',
            'position_mode': 'getStaticPosInit'
        }
        
        for key, cmd in commands.items():
            response = self.send_command(cmd)
            if response:
                config[key] = response
        
        return config
