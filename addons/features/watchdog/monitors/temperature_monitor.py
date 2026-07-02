"""
Temperature Monitor - Check system CPU temperature
"""

import logging
from pathlib import Path
from typing import Dict, List

logger = logging.getLogger(__name__)


class TemperatureMonitor:
    """Monitor CPU temperature (Raspberry Pi / Linux)"""
    
    # Common thermal zone paths
    THERMAL_PATHS = [
        '/sys/class/thermal/thermal_zone0/temp',  # RPi
        '/sys/class/thermal/thermal_zone1/temp',  # Some systems
        '/sys/devices/virtual/thermal/thermal_zone0/temp'  # Alternative
    ]
    
    def __init__(self, config: Dict):
        """
        Initialize temperature monitor
        
        Args:
            config: Monitor configuration
        """
        self.config = config
        self.enabled = config.get('enabled', True)
        self.warning_threshold = config.get('warning_threshold', 70)  # Celsius
        self.critical_threshold = config.get('critical_threshold', 80)
        self.thermal_path = self._find_thermal_zone()
    
    def check(self) -> Dict:
        """
        Check system temperature
        
        Returns:
            Dict with check results and any incidents
        """
        if not self.enabled:
            return {'status': 'disabled', 'incidents': []}
        
        incidents = []
        
        try:
            temp_celsius = self._read_temperature()
            
            if temp_celsius is None:
                incidents.append({
                    'type': 'temperature',
                    'severity': 'warning',
                    'message': 'Не може да се прочете температурата на CPU'
                })
                return {'status': 'error', 'incidents': incidents, 'temperature': None}
            
            # Check thresholds
            if temp_celsius >= self.critical_threshold:
                incidents.append({
                    'type': 'temperature',
                    'severity': 'critical',
                    'message': f'Критична температура: {temp_celsius:.1f}°C (праг: {self.critical_threshold}°C)'
                })
            elif temp_celsius >= self.warning_threshold:
                incidents.append({
                    'type': 'temperature',
                    'severity': 'warning',
                    'message': f'Висока температура: {temp_celsius:.1f}°C (праг: {self.warning_threshold}°C)'
                })
            
            status = 'critical' if temp_celsius >= self.critical_threshold else \
                     'warning' if temp_celsius >= self.warning_threshold else 'ok'
            
            return {
                'status': status,
                'incidents': incidents,
                'temperature': temp_celsius,
                'thermal_path': str(self.thermal_path) if self.thermal_path else None
            }
            
        except Exception as e:
            logger.error(f"Temperature check failed: {e}")
            incidents.append({
                'type': 'temperature',
                'severity': 'warning',
                'message': f'Грешка при проверка на температурата: {str(e)}'
            })
            return {'status': 'error', 'incidents': incidents}
    
    def _find_thermal_zone(self) -> Path:
        """Find available thermal zone file"""
        for path_str in self.THERMAL_PATHS:
            path = Path(path_str)
            if path.exists():
                logger.info(f"Found thermal zone: {path}")
                return path
        
        logger.warning("No thermal zone found")
        return None
    
    def _read_temperature(self) -> float:
        """
        Read temperature from thermal zone
        
        Returns:
            Temperature in Celsius, or None if unavailable
        """
        if not self.thermal_path or not self.thermal_path.exists():
            return None
        
        try:
            # Read raw value (in millidegrees)
            raw_temp = self.thermal_path.read_text().strip()
            temp_millidegrees = int(raw_temp)
            
            # Convert to Celsius
            temp_celsius = temp_millidegrees / 1000.0
            
            logger.debug(f"Temperature: {temp_celsius:.1f}°C")
            return temp_celsius
            
        except Exception as e:
            logger.error(f"Failed to read temperature: {e}")
            return None
