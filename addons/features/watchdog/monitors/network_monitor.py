"""
Network Monitor - Check internet and VPN connectivity
"""

import logging
import subprocess
import time
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
        Check if VPN interface is up AND actually passing traffic.

        A WireGuard interface can remain administratively "up" (ip link
        shows UP state) even when its private key has been corrupted or
        silently regenerated and no handshake can ever complete - link
        state alone cannot detect this. This check additionally confirms
        at least one peer has a recent handshake via "wg show <iface>
        latest-handshakes" before reporting the tunnel healthy.

        Returns:
            True if the interface exists, is administratively up, AND at
            least one peer has a handshake within vpn_handshake_max_age_seconds
            (default 300s - generous relative to the typical 25s
            PersistentKeepalive, to avoid false positives from transient
            keepalive delays).
        """
        interface = self.config.get('vpn_interface', 'wg0')
        handshake_max_age_seconds = self.config.get('vpn_handshake_max_age_seconds', 300)

        try:
            link_result = subprocess.run(
                ['ip', 'link', 'show', interface],
                capture_output=True,
                text=True
            )

            if link_result.returncode != 0:
                return False

            link_output = link_result.stdout.lower()
            if not ('state up' in link_output or '<up,' in link_output):
                return False

            handshake_result = subprocess.run(
                ['wg', 'show', interface, 'latest-handshakes'],
                capture_output=True,
                text=True
            )

            if handshake_result.returncode != 0:
                logger.warning(
                    f"'wg show {interface} latest-handshakes' failed "
                    f"(returncode={handshake_result.returncode}): "
                    f"{handshake_result.stderr.strip()}"
                )
                return False

            now = time.time()
            for line in handshake_result.stdout.strip().splitlines():
                parts = line.split()
                if len(parts) < 2:
                    continue
                try:
                    handshake_ts = int(parts[1])
                except ValueError:
                    continue
                if handshake_ts > 0 and (now - handshake_ts) <= handshake_max_age_seconds:
                    return True

            return False

        except Exception as e:
            logger.error(f"Failed to check VPN interface: {e}")
            return False
