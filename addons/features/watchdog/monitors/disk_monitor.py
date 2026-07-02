"""
Disk Monitor - Monitor disk space usage
"""

import logging
import subprocess
import shutil
from typing import Dict, List
from pathlib import Path

logger = logging.getLogger(__name__)


class DiskMonitor:
    """Monitor disk space usage"""
    
    def __init__(self, config: Dict):
        """
        Initialize disk monitor
        
        Args:
            config: Disk monitor configuration
        """
        self.config = config
    
    def check(self) -> Dict:
        """
        Check disk space on configured paths
        
        Returns:
            Dict with disk status and incidents
        """
        results = {
            'status': 'ok',
            'disks': {},
            'incidents': []
        }
        
        warning_threshold = self.config.get('warning_threshold_percent', 80)
        critical_threshold = self.config.get('critical_threshold_percent', 90)
        check_paths = self.config.get('check_paths', ['/home', '/var', '/'])
        
        for path in check_paths:
            try:
                disk_usage = self._get_disk_usage(path)
                results['disks'][path] = disk_usage
                
                percent_used = disk_usage['percent_used']
                
                if percent_used >= critical_threshold:
                    results['status'] = 'critical'
                    results['incidents'].append({
                        'type': 'disk_critical',
                        'severity': 'critical',
                        'path': path,
                        'percent_used': percent_used,
                        'message': f'Disk space critical on {path}: {percent_used}% used'
                    })
                
                elif percent_used >= warning_threshold:
                    if results['status'] == 'ok':
                        results['status'] = 'warning'
                    
                    if self.config.get('alert_on_warning', True):
                        results['incidents'].append({
                            'type': 'disk_warning',
                            'severity': 'warning',
                            'path': path,
                            'percent_used': percent_used,
                            'message': f'Disk space warning on {path}: {percent_used}% used'
                        })
                
            except Exception as e:
                logger.error(f"Failed to check disk space for {path}: {e}")
                results['disks'][path] = {'error': str(e)}
        
        return results
    
    def _get_disk_usage(self, path: str) -> Dict:
        """
        Get disk usage for a path
        
        Args:
            path: Path to check
            
        Returns:
            Dict with disk usage info
        """
        try:
            stat = shutil.disk_usage(path)
            
            return {
                'total_gb': stat.total / (1024**3),
                'used_gb': stat.used / (1024**3),
                'free_gb': stat.free / (1024**3),
                'percent_used': (stat.used / stat.total) * 100
            }
            
        except Exception as e:
            raise Exception(f"Failed to get disk usage: {e}")
