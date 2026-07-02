"""
U-blox ZED-F9P Configuration
UBX protocol implementation
"""

import logging
import serial
import struct
import time
from typing import Dict, List, Optional, Tuple

logger = logging.getLogger(__name__)


class UBXMessage:
    """UBX message builder and parser"""
    
    SYNC_CHAR_1 = 0xB5
    SYNC_CHAR_2 = 0x62
    
    @staticmethod
    def calculate_checksum(msg_class: int, msg_id: int, payload: bytes) -> Tuple[int, int]:
        """Calculate UBX checksum"""
        ck_a = 0
        ck_b = 0
        
        for byte in [msg_class, msg_id, len(payload) & 0xFF, (len(payload) >> 8) & 0xFF] + list(payload):
            ck_a = (ck_a + byte) & 0xFF
            ck_b = (ck_b + ck_a) & 0xFF
        
        return ck_a, ck_b
    
    @classmethod
    def build(cls, msg_class: int, msg_id: int, payload: bytes = b'') -> bytes:
        """Build UBX message with checksum"""
        ck_a, ck_b = cls.calculate_checksum(msg_class, msg_id, payload)
        
        return bytes([
            cls.SYNC_CHAR_1, cls.SYNC_CHAR_2,
            msg_class, msg_id,
            len(payload) & 0xFF, (len(payload) >> 8) & 0xFF
        ]) + payload + bytes([ck_a, ck_b])


class ZEDF9PConfigurator:
    """ZED-F9P receiver configuration"""
    
    # UBX message classes and IDs
    CLASS_CFG = 0x06
    CLASS_MON = 0x0A
    CLASS_NAV = 0x01
    
    CFG_VALSET = 0x8A
    CFG_VALGET = 0x8B
    CFG_RST = 0x04
    MON_VER = 0x04
    
    # Configuration keys (CFG-VALSET)
    CFG_KEYS = {
        'UART1_BAUDRATE': 0x40520001,
        'UART1_INPROT_UBX': 0x10730001,
        'UART1_INPROT_RTCM3X': 0x10730004,
        'UART1_OUTPROT_UBX': 0x10740001,
        'UART1_OUTPROT_RTCM3X': 0x10740004,
        'MSGOUT_RTCM_3X_TYPE1005_UART1': 0x209102bd,
        'MSGOUT_RTCM_3X_TYPE1077_UART1': 0x209102cc,
        'MSGOUT_RTCM_3X_TYPE1087_UART1': 0x209102d1,
        'MSGOUT_RTCM_3X_TYPE1097_UART1': 0x20910318,
        'MSGOUT_RTCM_3X_TYPE1127_UART1': 0x209102d6,
        'MSGOUT_RTCM_3X_TYPE1230_UART1': 0x20910303,
        'TMODE_MODE': 0x20030001,  # Time mode: 0=disabled, 1=survey-in, 2=fixed
        'TMODE_SVIN_MIN_DUR': 0x40030010,  # Survey-in min duration (s)
        'TMODE_SVIN_ACC_LIMIT': 0x40030011,  # Survey-in accuracy limit (0.1mm)
        'TMODE_POS_TYPE': 0x20030007,  # 0=ECEF, 1=LLH
        'TMODE_ECEF_X': 0x40030009,
        'TMODE_ECEF_Y': 0x4003000a,
        'TMODE_ECEF_Z': 0x4003000b,
        'TMODE_LAT': 0x40030013,
        'TMODE_LON': 0x40030014,
        'TMODE_HEIGHT': 0x40030015
    }
    
    def __init__(self, port: str, baudrate: int = 115200):
        """
        Initialize ZED-F9P configurator
        
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
            logger.info(f"✓ Connected to ZED-F9P on {self.port}")
            return True
        except Exception as e:
            logger.error(f"Failed to connect: {e}")
            return False
    
    def disconnect(self):
        """Disconnect from receiver"""
        if self.serial and self.serial.is_open:
            self.serial.close()
            logger.info("Disconnected from ZED-F9P")
    
    def get_version(self) -> Optional[Dict]:
        """Get receiver firmware version"""
        if not self.serial or not self.serial.is_open:
            return None
        
        try:
            # Send UBX-MON-VER
            msg = UBXMessage.build(self.CLASS_MON, self.MON_VER)
            self.serial.write(msg)
            time.sleep(0.5)
            
            response = self.serial.read(1024)
            if len(response) > 40:
                sw_version = response[6:36].decode('ascii', errors='ignore').strip('\x00')
                hw_version = response[36:46].decode('ascii', errors='ignore').strip('\x00')
                
                return {
                    'software': sw_version,
                    'hardware': hw_version
                }
        except Exception as e:
            logger.error(f"Get version failed: {e}")
        
        return None
    
    def set_rtcm_messages(self, messages: List[int], rate: int = 1) -> bool:
        """
        Configure RTCM3 message output
        
        Args:
            messages: List of RTCM message types (1005, 1077, 1087, etc.)
            rate: Output rate (0=off, 1=every epoch, N=every N epochs)
            
        Returns:
            True if successful
        """
        if not self.serial or not self.serial.is_open:
            return False
        
        try:
            for msg_type in messages:
                key_name = f'MSGOUT_RTCM_3X_TYPE{msg_type}_UART1'
                
                if key_name in self.CFG_KEYS:
                    self._set_config_value(self.CFG_KEYS[key_name], rate, 'U1')
                    logger.info(f"✓ Enabled RTCM {msg_type} at rate {rate}")
            
            return True
        except Exception as e:
            logger.error(f"Set RTCM messages failed: {e}")
            return False
    
    def set_base_mode(self, mode: str, **kwargs) -> bool:
        """
        Configure base station mode
        
        Args:
            mode: 'survey-in' or 'fixed'
            **kwargs: Mode-specific parameters
                For survey-in: min_duration (s), accuracy_limit (mm)
                For fixed: lat, lon, height OR ecef_x, ecef_y, ecef_z
                
        Returns:
            True if successful
        """
        if not self.serial or not self.serial.is_open:
            return False
        
        try:
            if mode == 'survey-in':
                # Enable survey-in mode
                self._set_config_value(self.CFG_KEYS['TMODE_MODE'], 1, 'U1')
                
                min_dur = kwargs.get('min_duration', 300)
                acc_limit = kwargs.get('accuracy_limit', 50000)  # 5.0m in 0.1mm units
                
                self._set_config_value(self.CFG_KEYS['TMODE_SVIN_MIN_DUR'], min_dur, 'U4')
                self._set_config_value(self.CFG_KEYS['TMODE_SVIN_ACC_LIMIT'], acc_limit, 'U4')
                
                logger.info(f"✓ Survey-in mode: {min_dur}s, {acc_limit*0.1}mm")
                
            elif mode == 'fixed':
                # Enable fixed mode
                self._set_config_value(self.CFG_KEYS['TMODE_MODE'], 2, 'U1')
                
                if 'lat' in kwargs and 'lon' in kwargs and 'height' in kwargs:
                    # LLH mode
                    self._set_config_value(self.CFG_KEYS['TMODE_POS_TYPE'], 1, 'U1')
                    self._set_config_value(self.CFG_KEYS['TMODE_LAT'], int(kwargs['lat'] * 1e7), 'I4')
                    self._set_config_value(self.CFG_KEYS['TMODE_LON'], int(kwargs['lon'] * 1e7), 'I4')
                    self._set_config_value(self.CFG_KEYS['TMODE_HEIGHT'], int(kwargs['height'] * 100), 'I4')
                    
                    logger.info(f"✓ Fixed mode (LLH): {kwargs['lat']}, {kwargs['lon']}, {kwargs['height']}")
                    
                elif 'ecef_x' in kwargs and 'ecef_y' in kwargs and 'ecef_z' in kwargs:
                    # ECEF mode
                    self._set_config_value(self.CFG_KEYS['TMODE_POS_TYPE'], 0, 'U1')
                    self._set_config_value(self.CFG_KEYS['TMODE_ECEF_X'], int(kwargs['ecef_x'] * 100), 'I4')
                    self._set_config_value(self.CFG_KEYS['TMODE_ECEF_Y'], int(kwargs['ecef_y'] * 100), 'I4')
                    self._set_config_value(self.CFG_KEYS['TMODE_ECEF_Z'], int(kwargs['ecef_z'] * 100), 'I4')
                    
                    logger.info(f"✓ Fixed mode (ECEF): {kwargs['ecef_x']}, {kwargs['ecef_y']}, {kwargs['ecef_z']}")
                else:
                    logger.error("Fixed mode requires lat/lon/height OR ecef_x/y/z")
                    return False
            else:
                logger.error(f"Unknown mode: {mode}")
                return False
            
            return True
            
        except Exception as e:
            logger.error(f"Set base mode failed: {e}")
            return False
    
    def _set_config_value(self, key_id: int, value: int, value_type: str):
        """Set configuration value using CFG-VALSET"""
        # Build payload
        layers = 0x07  # RAM + BBR + Flash
        transaction = 0x00
        reserved = 0x00
        
        # Encode value based on type
        if value_type == 'U1':
            value_bytes = struct.pack('<B', value)
        elif value_type == 'U2':
            value_bytes = struct.pack('<H', value)
        elif value_type == 'U4':
            value_bytes = struct.pack('<I', value)
        elif value_type == 'I4':
            value_bytes = struct.pack('<i', value)
        else:
            raise ValueError(f"Unsupported value type: {value_type}")
        
        payload = struct.pack('<BBBxI', layers, transaction, reserved, key_id) + value_bytes
        
        msg = UBXMessage.build(self.CLASS_CFG, self.CFG_VALSET, payload)
        self.serial.write(msg)
        time.sleep(0.1)
    
    def save_config(self) -> bool:
        """Save configuration to flash memory"""
        if not self.serial or not self.serial.is_open:
            return False
        
        try:
            # CFG-CFG message to save
            payload = struct.pack('<III', 0xFFFFFFFF, 0, 0)  # Save all, clear none, load none
            msg = UBXMessage.build(self.CLASS_CFG, 0x09, payload)
            
            self.serial.write(msg)
            time.sleep(0.5)
            
            logger.info("✓ Configuration saved to flash")
            return True
        except Exception as e:
            logger.error(f"Save config failed: {e}")
            return False
    
    def reset_receiver(self, reset_type: str = 'hot') -> bool:
        """
        Reset receiver
        
        Args:
            reset_type: 'hot', 'warm', 'cold'
        """
        if not self.serial or not self.serial.is_open:
            return False
        
        reset_modes = {'hot': 0x0000, 'warm': 0x0001, 'cold': 0xFFFF}
        mode = reset_modes.get(reset_type, 0x0000)
        
        try:
            payload = struct.pack('<HBB', mode, 0, 0)
            msg = UBXMessage.build(self.CLASS_CFG, self.CFG_RST, payload)
            
            self.serial.write(msg)
            logger.info(f"✓ Receiver reset ({reset_type})")
            return True
        except Exception as e:
            logger.error(f"Reset failed: {e}")
            return False
