"""
CPU Monitor - Check CPU usage
"""

import logging
from typing import Dict, List

try:
    import psutil
    PSUTIL_AVAILABLE = True
except ImportError:
    PSUTIL_AVAILABLE = False
    logging.warning("psutil not available - CPU monitoring disabled")

logger = logging.getLogger(__name__)


class CPUMonitor:
    """Monitor CPU usage percentage"""
    
    def __init__(self, config: Dict):
        """
        Initialize CPU monitor
        
        Args:
            config: Monitor configuration
        """
        self.config = config
        self.enabled = config.get('enabled', True) and PSUTIL_AVAILABLE
        self.warning_threshold = config.get('warning_threshold', 80)  # Percent
        self.critical_threshold = config.get('critical_threshold', 95)
        self.check_interval = config.get('check_interval_seconds', 1)
    
    def check(self) -> Dict:
        """
        Check CPU usage
        
        Returns:
            Dict with check results and any incidents
        """
        if not self.enabled:
            return {'status': 'disabled', 'incidents': []}
        
        if not PSUTIL_AVAILABLE:
            return {
                'status': 'error',
                'incidents': [{
                    'type': 'cpu',
                    'severity': 'warning',
                    'message': 'psutil библиотеката не е инсталирана'
                }]
            }
        
        incidents = []
        
        try:
            # Get CPU usage (blocking call with interval)
            cpu_percent = psutil.cpu_percent(interval=self.check_interval)
            
            # Get per-core usage
            per_cpu = psutil.cpu_percent(interval=0, percpu=True)
            
            # Check thresholds
            if cpu_percent >= self.critical_threshold:
                incidents.append({
                    'type': 'cpu',
                    'severity': 'critical',
                    'message': f'Критично CPU натоварване: {cpu_percent:.1f}% (праг: {self.critical_threshold}%)'
                })
            elif cpu_percent >= self.warning_threshold:
                incidents.append({
                    'type': 'cpu',
                    'severity': 'warning',
                    'message': f'Високо CPU натоварване: {cpu_percent:.1f}% (праг: {self.warning_threshold}%)'
                })
            
            status = 'critical' if cpu_percent >= self.critical_threshold else \
                     'warning' if cpu_percent >= self.warning_threshold else 'ok'
            
            return {
                'status': status,
                'incidents': incidents,
                'cpu_percent': cpu_percent,
                'cpu_count': psutil.cpu_count(),
                'per_cpu': per_cpu
            }
            
        except Exception as e:
            logger.error(f"CPU check failed: {e}")
            incidents.append({
                'type': 'cpu',
                'severity': 'warning',
                'message': f'Грешка при проверка на CPU: {str(e)}'
            })
            return {'status': 'error', 'incidents': incidents}
