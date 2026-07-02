"""
Network Monitor - Check internet and VPN connectivity
"""

import logging
import subprocess
from typing import Dict, List

logger = logging.getLogger(__name__)


class NetworkMonitor:
    """Monitor network connectivity"""
    
    def __init__(self, config: Dict):
        """
        Initialize network monitor
        
        Args:
            config: Network monitor configuration
        """
        self.config = config
    
    def check(self) -> Dict:
        """
        Check network connectivity
        
        Returns:
            Dict with network status and incidents
        """
        results = {
            'status': 'ok',
            'checks': {},
            'incidents': []
        }
        
        # Check internet connectivity
        if self.config.get('check_internet', True):
            internet_ok = self._check_internet()
            results['checks']['internet'] = internet_ok
            
            if not internet_ok:
                results['status'] = 'critical'
                results['incidents'].append({
                    'type': 'internet_down',
                    'severity': 'critical',
                    'message': 'Internet connectivity lost'
                })
        
        # Check VPN
        if self.config.get('check_vpn', False):
            vpn_ok = self._check_vpn()
            results['checks']['vpn'] = vpn_ok
            
            if not vpn_ok:
                results['status'] = 'warning'
                results['incidents'].append({
                    'type': 'vpn_down',
                    'severity': 'warning',
                    'message': f'VPN interface {self.config.get("vpn_interface", "wg0")} is down'
                })
        
        return results
    
    def _check_internet(self) -> bool:
        """
        Check internet connectivity by pinging hosts
        
        Returns:
            True if internet is reachable
        """
        hosts = self.config.get('ping_hosts', ['8.8.8.8'])
        
        for host in hosts:
            try:
                result = subprocess.run(
                    ['ping', '-c', '1', '-W', '3', host],
                    capture_output=True,
                    timeout=5
                )
                
                if result.returncode == 0:
                    return True
                    
            except Exception as e:
                logger.debug(f"Ping to {host} failed: {e}")
                continue
        
        return False
    
    def _check_vpn(self) -> bool:
        """
        Check if VPN interface is up
        
        Returns:
            True if VPN interface exists and is up
        """
        interface = self.config.get('vpn_interface', 'wg0')
        
        try:
            result = subprocess.run(
                ['ip', 'link', 'show', interface],
                capture_output=True,
                text=True
            )
            
            if result.returncode == 0:
                # Check if interface is UP
                output = result.stdout.lower()
                return 'state up' in output or '<up,' in output
            
            return False
            
        except Exception as e:
            logger.error(f"Failed to check VPN interface: {e}")
            return False
