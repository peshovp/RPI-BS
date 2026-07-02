"""
Memory Monitor - Check RAM and swap usage
"""

import logging
from typing import Dict, List

try:
    import psutil
    PSUTIL_AVAILABLE = True
except ImportError:
    PSUTIL_AVAILABLE = False
    logging.warning("psutil not available - Memory monitoring disabled")

logger = logging.getLogger(__name__)


class MemoryMonitor:
    """Monitor system memory (RAM) usage"""
    
    def __init__(self, config: Dict):
        """
        Initialize memory monitor
        
        Args:
            config: Monitor configuration
        """
        self.config = config
        self.enabled = config.get('enabled', True) and PSUTIL_AVAILABLE
        self.warning_threshold = config.get('warning_threshold', 80)  # Percent
        self.critical_threshold = config.get('critical_threshold', 90)
        self.check_swap = config.get('check_swap', True)
    
    def check(self) -> Dict:
        """
        Check memory usage
        
        Returns:
            Dict with check results and any incidents
        """
        if not self.enabled:
            return {'status': 'disabled', 'incidents': []}
        
        if not PSUTIL_AVAILABLE:
            return {
                'status': 'error',
                'incidents': [{
                    'type': 'memory',
                    'severity': 'warning',
                    'message': 'psutil библиотеката не е инсталирана'
                }]
            }
        
        incidents = []
        
        try:
            # Get virtual memory stats
            mem = psutil.virtual_memory()
            mem_percent = mem.percent
            
            # Check RAM thresholds
            if mem_percent >= self.critical_threshold:
                incidents.append({
                    'type': 'memory',
                    'severity': 'critical',
                    'message': f'Критично RAM запълване: {mem_percent:.1f}% ' \
                              f'({self._bytes_to_gb(mem.used):.1f}GB / {self._bytes_to_gb(mem.total):.1f}GB)'
                })
            elif mem_percent >= self.warning_threshold:
                incidents.append({
                    'type': 'memory',
                    'severity': 'warning',
                    'message': f'Високо RAM запълване: {mem_percent:.1f}% ' \
                              f'({self._bytes_to_gb(mem.used):.1f}GB / {self._bytes_to_gb(mem.total):.1f}GB)'
                })
            
            # Check swap if enabled
            swap_status = None
            if self.check_swap:
                swap = psutil.swap_memory()
                swap_percent = swap.percent
                
                if swap_percent > 50:  # Swap usage above 50% is concerning
                    incidents.append({
                        'type': 'memory',
                        'severity': 'warning',
                        'message': f'Високо Swap използване: {swap_percent:.1f}% ' \
                                  f'({self._bytes_to_gb(swap.used):.1f}GB / {self._bytes_to_gb(swap.total):.1f}GB)'
                    })
                
                swap_status = {
                    'percent': swap_percent,
                    'total_gb': self._bytes_to_gb(swap.total),
                    'used_gb': self._bytes_to_gb(swap.used),
                    'free_gb': self._bytes_to_gb(swap.free)
                }
            
            status = 'critical' if mem_percent >= self.critical_threshold else \
                     'warning' if mem_percent >= self.warning_threshold else 'ok'
            
            return {
                'status': status,
                'incidents': incidents,
                'memory_percent': mem_percent,
                'memory_total_gb': self._bytes_to_gb(mem.total),
                'memory_used_gb': self._bytes_to_gb(mem.used),
                'memory_available_gb': self._bytes_to_gb(mem.available),
                'swap': swap_status
            }
            
        except Exception as e:
            logger.error(f"Memory check failed: {e}")
            incidents.append({
                'type': 'memory',
                'severity': 'warning',
                'message': f'Грешка при проверка на паметта: {str(e)}'
            })
            return {'status': 'error', 'incidents': incidents}
    
    @staticmethod
    def _bytes_to_gb(bytes_value: int) -> float:
        """Convert bytes to gigabytes"""
        return bytes_value / (1024 ** 3)
