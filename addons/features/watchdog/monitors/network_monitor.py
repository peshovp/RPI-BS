"""
Network Monitor - Check internet and VPN connectivity
"""

import logging
import subprocess
import time
import json
from typing import Dict, List
from datetime import datetime
from pathlib import Path

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
        self.restart_history_file = Path("/var/lib/rtkbase/vpn_restart_history.json")
        self.restart_history = self._load_restart_history()

    def _load_restart_history(self) -> Dict:
        """Load VPN restart history from file"""
        if self.restart_history_file.exists():
            try:
                with open(self.restart_history_file, 'r') as f:
                    return json.load(f)
            except Exception:
                pass
        return {}

    def _save_restart_history(self):
        """Save VPN restart history to file"""
        try:
            self.restart_history_file.parent.mkdir(parents=True, exist_ok=True)
            with open(self.restart_history_file, 'w') as f:
                json.dump(self.restart_history, f, indent=2)
        except Exception as e:
            logger.error(f"Failed to save VPN restart history: {e}")

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
            interface = self.config.get('vpn_interface', 'wg0')

            if not vpn_ok:
                results['status'] = 'warning'

                if self.config.get('vpn_auto_restart', True):
                    if self._should_restart_vpn(interface):
                        restart_success = self._restart_vpn(interface)

                        if restart_success:
                            results['incidents'].append({
                                'type': 'vpn_restarted',
                                'severity': 'warning',
                                'message': f'VPN interface {interface} had no recent handshake and has been restarted (likely a stale DNS-resolved endpoint, e.g. dynamic DNS IP change)',
                                'timestamp': datetime.utcnow().isoformat()
                            })
                        else:
                            results['status'] = 'critical'
                            results['incidents'].append({
                                'type': 'vpn_restart_failed',
                                'severity': 'critical',
                                'message': f'VPN interface {interface} has no recent handshake and restart failed',
                                'timestamp': datetime.utcnow().isoformat()
                            })
                    else:
                        results['incidents'].append({
                            'type': 'vpn_down',
                            'severity': 'warning',
                            'message': f'VPN interface {interface} is down (restart limit reached or in cooldown)',
                            'timestamp': datetime.utcnow().isoformat()
                        })
                else:
                    results['incidents'].append({
                        'type': 'vpn_down',
                        'severity': 'warning',
                        'message': f'VPN interface {interface} is down (auto-restart disabled)',
                        'timestamp': datetime.utcnow().isoformat()
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

    def _should_restart_vpn(self, interface: str) -> bool:
        """
        Check if the VPN interface should be restarted, based on a cooldown
        and a rolling attempt-limit window, mirroring ServiceMonitor's
        _should_restart() logic exactly (see service_monitor.py).

        Args:
            interface: WireGuard interface name (e.g. "wg0")

        Returns:
            True if a restart attempt should be made now
        """
        now = datetime.utcnow()
        max_attempts = self.config.get('vpn_max_restart_attempts', 3)
        cooldown_seconds = self.config.get('vpn_restart_cooldown_seconds', 300)

        if interface not in self.restart_history:
            self.restart_history[interface] = {
                'attempts': 0,
                'last_restart': None,
                'window_start': now.isoformat()
            }

        interface_history = self.restart_history[interface]

        # Check cooldown
        if interface_history.get('last_restart'):
            last_restart = datetime.fromisoformat(interface_history['last_restart'])
            if (now - last_restart).total_seconds() < cooldown_seconds:
                return False

        # Reset counter if window expired (1 hour)
        window_start = datetime.fromisoformat(interface_history['window_start'])
        if (now - window_start).total_seconds() > 3600:
            interface_history['attempts'] = 0
            interface_history['window_start'] = now.isoformat()

        # Check attempt limit
        if interface_history['attempts'] >= max_attempts:
            return False

        return True

    def _restart_vpn(self, interface: str) -> bool:
        """
        Restart the WireGuard interface via wg-quick@<interface>.service.

        This forces a fresh DNS re-resolution of the peer's Endpoint
        (e.g. a dynamic DNS hostname), which is the fix for the specific
        failure mode debugged this session: WireGuard resolves its peer's
        endpoint hostname only once at interface bring-up and never
        re-resolves it afterwards, so if the remote router's public IP
        changes (dynamic DNS), the tunnel silently stops passing traffic
        until something forces a fresh "wg-quick down && wg-quick up"
        cycle - previously only discoverable/fixable by SSHing in
        manually. This closes that loop automatically.

        Args:
            interface: WireGuard interface name (e.g. "wg0")

        Returns:
            True if restart succeeded
        """
        service_name = f"wg-quick@{interface}.service"
        try:
            logger.info(f"Attempting to restart {service_name} (stale/missing VPN handshake)...")

            result = subprocess.run(
                ['systemctl', 'restart', service_name],
                capture_output=True,
                text=True,
                timeout=30
            )

            if result.returncode == 0:
                now = datetime.utcnow()
                if interface not in self.restart_history:
                    self.restart_history[interface] = {
                        'attempts': 0,
                        'window_start': now.isoformat()
                    }

                self.restart_history[interface]['attempts'] += 1
                self.restart_history[interface]['last_restart'] = now.isoformat()
                self._save_restart_history()

                logger.info(f"Successfully restarted {service_name}")
                return True
            else:
                logger.error(f"Failed to restart {service_name}: {result.stderr}")
                return False

        except Exception as e:
            logger.error(f"Exception while restarting {service_name}: {e}")
            return False

    def get_restart_history(self) -> Dict:
        """Get VPN restart history"""
        return self.restart_history

    def reset_restart_counter(self, interface: str):
        """Reset restart counter for a VPN interface"""
        if interface in self.restart_history:
            self.restart_history[interface]['attempts'] = 0
            self.restart_history[interface]['window_start'] = datetime.utcnow().isoformat()
            self._save_restart_history()
