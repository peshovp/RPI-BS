"""
GNSS Monitor - Monitor GNSS receiver connectivity
"""

import logging
import subprocess
import serial
from typing import Dict
from pathlib import Path

logger = logging.getLogger(__name__)


class GNSSMonitor:
    """Monitor GNSS receiver data stream"""
    
    def __init__(self, config: Dict):
        """
        Initialize GNSS monitor
        
        Args:
            config: GNSS monitor configuration
        """
        self.config = config
    
    def check(self) -> Dict:
        """
        Check GNSS receiver connectivity
        
        Returns:
            Dict with GNSS status and incidents
        """
        results = {
            'status': 'ok',
            'receiver': {},
            'incidents': []
        }
        
        if not self.config.get('check_data_stream', True):
            results['receiver']['checked'] = False
            return results
        
        # Check serial port connectivity
        serial_port = self.config.get('serial_port', '/dev/ttyACM0')
        port_exists = Path(serial_port).exists()
        
        results['receiver']['serial_port'] = serial_port
        results['receiver']['port_exists'] = port_exists
        
        if not port_exists:
            results['status'] = 'critical'
            results['incidents'].append({
                'type': 'gnss_disconnected',
                'severity': 'critical',
                'message': f'GNSS receiver not found at {serial_port}'
            })
            return results
        
        # Try to read data from receiver
        data_ok = self._check_data_stream(serial_port)
        results['receiver']['data_streaming'] = data_ok
        
        if not data_ok:
            results['status'] = 'warning'
            
            if self.config.get('alert_on_failure', True):
                results['incidents'].append({
                    'type': 'gnss_no_data',
                    'severity': 'warning',
                    'message': f'GNSS receiver at {serial_port} is not streaming data'
                })
        
        return results
    
    def _check_data_stream(self, serial_port: str) -> bool:
        """
        Check if data is coming from receiver
        
        Args:
            serial_port: Serial port path
            
        Returns:
            True if data is streaming
        """
        timeout = self.config.get('timeout_seconds', 10)
        
        try:
            # Try to open serial port and read some data
            with serial.Serial(serial_port, baudrate=115200, timeout=timeout) as ser:
                # Read a few lines to ensure data is flowing
                for _ in range(5):
                    line = ser.readline()
                    if line:
                        # Got data - receiver is streaming
                        return True
                
                # No data received
                return False
                
        except serial.SerialException as e:
            logger.error(f"Serial port error: {e}")
            return False
        except Exception as e:
            logger.error(f"Failed to check GNSS data stream: {e}")
            return False
