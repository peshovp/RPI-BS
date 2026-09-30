"""
Network Monitor - Check internet and VPN connectivity
"""

import logging
import subprocess
import time
import json
import socket
from typing import Dict, List, Optional
from datetime import datetime
from pathlib import Path

logger = logging.getLogger(__name__)

try:                                    # web app: repo root on sys.path
    from addons import dns_health
except ImportError:                     # run_watchdog_check.py: addons/ on sys.path
    try:
        import dns_health
    except ImportError:
        dns_health = None


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

        # Reachability: the default gateway (LAN) and the hosts this station
        # actually depends on (WireGuard peer endpoint, active NTRIP
        # casters) - never hard-coded public IPs.
        if self.config.get('check_internet', True):
            reach = self._check_reachability()
            results['checks']['lan'] = reach['gateway']['ok'] if reach['gateway'] else None
            results['checks']['internet'] = reach['internet_ok']
            if not reach['gateway']:
                results['status'] = 'critical'
                results['incidents'].append({
                    'type': 'no_default_route',
                    'severity': 'critical',
                    'message': 'No default route - the station has no LAN gateway'
                })
            elif not reach['gateway']['ok']:
                results['status'] = 'critical'
                results['incidents'].append({
                    'type': 'lan_down',
                    'severity': 'critical',
                    'message': f"Default gateway {reach['gateway']['host']} not reachable (LAN)"
                })
            if reach['internet_ok'] is False:
                results['status'] = 'critical'
                results['incidents'].append({
                    'type': 'internet_down',
                    'severity': 'critical',
                    'message': 'Internet targets not reachable: ' + '; '.join(
                        f"{t['kind']} {t['host']}{':' + str(t['port']) if t.get('port') else ''}: {t['detail']}"
                        for t in reach['targets'] if t['ok'] is False)
                })

        # DNS self-test through the system resolver (see addons/dns_health.py)
        if self.config.get('check_dns', True) and dns_health is not None:
            dns = self._check_dns()
            results['checks']['dns'] = dns.get('status')
            if dns.get('_fresh') and dns.get('status') != 'ok':
                severity = 'critical' if dns['status'] in ('no_dns', 'failed') else 'warning'
                if severity == 'critical' and results['status'] == 'ok':
                    results['status'] = 'critical'
                elif results['status'] == 'ok':
                    results['status'] = 'warning'
                results['incidents'].append({
                    'type': f"dns_{dns['status']}",
                    'severity': severity,
                    'message': f"DNS: {dns['message']}",
                    'timestamp': datetime.utcnow().isoformat()
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

    def _check_dns(self) -> Dict:
        """
        Run the DNS self-test at most every dns_check_interval_seconds
        (default 600 - it resolves several hosts, each up to 12 s when DNS
        is broken, while the watchdog itself runs every minute). Between
        runs the cached result is returned (without '_fresh', so no repeat
        incident). The result is saved for the UI either way.
        """
        interval = self.config.get('dns_check_interval_seconds', 600)
        cached = dns_health.load_status()
        if cached and cached.get('raise_incident'):
            # Written by tools/dns_setup.sh (e.g. the DNS migration rolled
            # back because the network's own DNS resolved nothing): raise
            # the incident once, keep the state for the card.
            cached.pop('raise_incident', None)
            dns_health.save_status(cached)
            logger.error(f"DNS: {cached.get('message')}")
            return {**cached, '_fresh': True}
        if cached:
            try:
                age = (datetime.utcnow() - datetime.fromisoformat(cached['timestamp']).replace(tzinfo=None)).total_seconds()
                if age < interval:
                    return cached
            except (KeyError, ValueError):
                pass
        status = dns_health.dns_self_test()
        dns_health.save_status(status)
        if status['status'] == 'ok':
            logger.info(f"DNS self-test: {status['message']}")
        elif status['status'] == 'no_dns':
            logger.error(f"DNS self-test: {status['message']}")
        else:
            logger.warning(f"DNS self-test ({status['status']}): {status['message']}")
        return {**status, '_fresh': True}

    # Where the reachability result is saved for the watchdog page.
    REACH_STATUS_FILE = Path("/var/lib/rtkbase/network_reach.json")
    SETTINGS_FILE = Path(__file__).resolve().parents[4] / "settings.conf"
    WG_DIR = Path("/etc/wireguard")

    @staticmethod
    def _ping(host: str) -> bool:
        try:
            return subprocess.run(['ping', '-c', '1', '-W', '3', host],
                                  capture_output=True, timeout=6).returncode == 0
        except Exception as e:
            logger.debug(f"Ping to {host} failed: {e}")
            return False

    @staticmethod
    def _tcp_connect(host: str, port: int, timeout: float = 5.0) -> Dict:
        """
        TCP connect to host:port - the service an NTRIP caster actually
        provides (many servers drop ICMP, so ping says nothing). The name is
        resolved through the system resolver (getaddrinfo = glibc), and a
        name that doesn't resolve is reported as DNS, not as unreachable.
        """
        try:
            infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
        except socket.gaierror as e:
            return {'resolved': False, 'ok': False, 'detail': f"does not resolve (DNS): {e}"}
        last = ''
        for family, socktype, proto, _, addr in infos:
            try:
                with socket.socket(family, socktype, proto) as s:
                    s.settimeout(timeout)
                    s.connect(addr)
                    return {'resolved': True, 'ok': True, 'detail': f"TCP connect to {addr[0]}:{port} OK"}
            except OSError as e:
                last = f"{addr[0]}:{port}: {e}"
        return {'resolved': True, 'ok': False, 'detail': f"no TCP connection ({last})"}

    @staticmethod
    def _wg_handshake_age(iface: str) -> Optional[int]:
        """Seconds since the most recent handshake of any peer on iface, or
        None if there has never been one / wg is unavailable."""
        try:
            out = subprocess.run(['wg', 'show', iface, 'latest-handshakes'],
                                 capture_output=True, text=True, timeout=5)
        except Exception:
            return None
        if out.returncode != 0:
            return None
        epochs = [int(p[1]) for p in (l.split() for l in out.stdout.splitlines())
                  if len(p) == 2 and p[1].isdigit() and int(p[1]) > 0]
        return int(time.time()) - max(epochs) if epochs else None

    @staticmethod
    def _default_gateway():
        try:
            out = subprocess.run(['ip', '-4', 'route', 'show', 'default'],
                                 capture_output=True, text=True, timeout=5).stdout
        except Exception:
            return None
        for line in out.splitlines():
            parts = line.split()
            if 'via' in parts:
                return parts[parts.index('via') + 1]
        return None

    def _internet_targets(self) -> List[Dict]:
        """
        What this station actually depends on on the internet:
        - its WireGuard tunnel ({'kind': 'wireguard', 'iface', 'host',
          'keepalive'}), from /etc/wireguard/<iface>.conf (the watchdog runs
          as root);
        - the casters of the NTRIP services that are active ({'kind':
          'caster', 'host', 'port'}), from settings.conf.
        """
        targets: List[Dict] = []
        iface = self.config.get('vpn_interface', 'wg0')
        try:
            host, keepalive = None, False
            for line in (self.WG_DIR / f"{iface}.conf").read_text().splitlines():
                key, _, value = line.partition('=')
                key, value = key.strip().lower(), value.strip()
                if key == 'endpoint' and value and host is None:
                    host = value[1:value.index(']')] if value.startswith('[') else value.rsplit(':', 1)[0]
                elif key == 'persistentkeepalive' and value.isdigit() and int(value) > 0:
                    keepalive = True
            if host:
                targets.append({'kind': 'wireguard', 'iface': iface, 'host': host, 'keepalive': keepalive})
        except OSError:
            pass
        try:
            from configparser import ConfigParser
            cfg = ConfigParser(interpolation=None)
            cfg.read(self.SETTINGS_FILE)
            for section, suffix, service in (('ntrip_A', 'a', 'str2str_ntrip_A'),
                                             ('ntrip_B', 'b', 'str2str_ntrip_B')):
                host = cfg.get(section, f'svr_addr_{suffix}', fallback='').strip().strip("'\"")
                port = cfg.get(section, f'svr_port_{suffix}', fallback='').strip().strip("'\"")
                if host and port.isdigit() and \
                        not any(t.get('host') == host and t.get('port') == int(port) for t in targets) and \
                        subprocess.run(['systemctl', 'is-active', '--quiet', service], timeout=5).returncode == 0:
                    targets.append({'kind': 'caster', 'host': host, 'port': int(port)})
        except Exception as e:
            logger.debug(f"reading caster hosts from {self.SETTINGS_FILE} failed: {e}")
        return targets

    def _check_reachability(self) -> Dict:
        """
        LAN: ping the default gateway.
        Internet, never by ICMP (many servers drop ping):
        - NTRIP caster: TCP connect to its configured host:port;
        - WireGuard (UDP - no TCP check possible): age of the latest
          handshake. With PersistentKeepalive set, traffic is expected and
          WireGuard re-handshakes every ~2 min, so older than
          wg_handshake_max_age_seconds (default 180) = tunnel problem.
          Without keepalive an idle tunnel legitimately has an old
          handshake, so it can't be judged ('ok' None).
        No hard-coded public IPs. With no such target, only the gateway is
        checked ('internet_ok' None) and the note says so.
        """
        gw = self._default_gateway()
        max_age = self.config.get('wg_handshake_max_age_seconds', 180)
        result = {'gateway': {'host': gw, 'ok': self._ping(gw)} if gw else None,
                  'targets': [], 'internet_ok': None, 'note': '',
                  'timestamp': datetime.utcnow().isoformat(timespec='seconds') + 'Z'}
        for t in self._internet_targets():
            if t['kind'] == 'caster':
                t.update(self._tcp_connect(t['host'], t['port']))
            else:
                age = self._wg_handshake_age(t['iface'])
                t['handshake_age_s'] = age
                if age is not None and age <= max_age:
                    t['ok'], t['detail'] = True, f"latest handshake {age} s ago"
                elif not t['keepalive']:
                    t['ok'] = None
                    t['detail'] = (f"latest handshake {age} s ago" if age is not None else "no handshake yet") + \
                                  " - no PersistentKeepalive, an idle tunnel can't be judged"
                else:
                    t['ok'] = False
                    t['detail'] = (f"no handshake for {age} s (> {max_age} s)" if age is not None
                                   else "no handshake since the interface came up")
            result['targets'].append(t)
        judged = [t['ok'] for t in result['targets'] if t['ok'] is not None]
        if judged:
            result['internet_ok'] = any(judged)
        elif not result['targets']:
            result['note'] = ('No WireGuard endpoint or active NTRIP caster found - '
                              'checking the LAN gateway only')
        try:
            self.REACH_STATUS_FILE.parent.mkdir(parents=True, exist_ok=True)
            self.REACH_STATUS_FILE.write_text(json.dumps(result, indent=2))
        except OSError as e:
            logger.debug(f"could not write {self.REACH_STATUS_FILE}: {e}")
        return result

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
