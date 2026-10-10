"""
Watchdog Controller - Main orchestration for system monitoring
"""

import logging
import json
import subprocess
from pathlib import Path
from typing import Dict, List, Any, Optional
from datetime import datetime, timedelta

logger = logging.getLogger(__name__)


class WatchdogController:
    """
    Main controller for Watchdog monitoring system
    
    Coordinates multiple monitoring modules:
    - ServiceMonitor: RTKBase services
    - NetworkMonitor: Connectivity
    - DiskMonitor: Storage
    - GNSSMonitor: Receiver
    """
    
    def __init__(self, config_file: str = "/var/lib/rtkbase/watchdog_config.json"):
        """
        Initialize Watchdog controller
        
        Args:
            config_file: Path to watchdog configuration
        """
        self.config_file = Path(config_file)
        self.config = self._load_config()
        self.incident_log_file = Path("/var/lib/rtkbase/watchdog_incidents.json")
        
        # Initialize monitors (lazy loading)
        self._service_monitor = None
        self._network_monitor = None
        self._disk_monitor = None
        self._gnss_monitor = None
        self._temperature_monitor = None
        self._cpu_monitor = None
        self._memory_monitor = None
        
        logger.info("Watchdog controller initialized")
    
    def _load_config(self) -> Dict:
        """Load watchdog configuration or create default, merging in any
        keys added to the in-code defaults since a config file was first
        written to disk (e.g. an existing installation's watchdog_config.json
        predates newer keys like vpn_auto_restart) - without this merge,
        get_config() would silently omit those keys forever for any station
        whose config file already existed, since the old code returned the
        loaded file verbatim with no defaults applied at all once the file
        was found to exist and parse successfully."""
        # Default configuration
        default_config = {
            'enabled': False,
            'check_interval_seconds': 60,  # Check every minute
            'monitors': {
                'service': {
                    'enabled': True,
                    'auto_restart': True,
                    'services': [
                        'str2str_tcp.service',
                        'rtkbase_web.service'
                    ],
                    'max_restart_attempts': 3,
                    'restart_cooldown_seconds': 300  # 5 minutes
                },
                'network': {
                    'enabled': True,
                    'check_internet': True,
                    'check_vpn': True,
                    # DNS self-test via the system resolver (addons/dns_health.py)
                    'check_dns': True,
                    'dns_check_interval_seconds': 600,
                    # No 'ping_hosts': LAN = ping the default gateway;
                    # internet = TCP connect to active NTRIP casters and the
                    # WireGuard handshake age (no ICMP, no public IPs) - see
                    # NetworkMonitor._check_reachability(). A 'ping_hosts' key
                    # left in an older saved config is ignored.
                    'wg_handshake_max_age_seconds': 180,
                    'vpn_interface': 'wg0',
                    'alert_on_failure': True,
                    'vpn_auto_restart': True,
                    'vpn_max_restart_attempts': 3,
                    'vpn_restart_cooldown_seconds': 300,
                    'vpn_handshake_max_age_seconds': 300
                },
                'disk': {
                    'enabled': True,
                    'warning_threshold_percent': 80,
                    'critical_threshold_percent': 90,
                    'check_paths': ['/home', '/var', '/'],
                    'alert_on_warning': True
                },
                'gnss': {
                    'enabled': True,
                    'check_data_stream': True,
                    'serial_port': '/dev/ttyACM0',
                    'timeout_seconds': 30,
                    'alert_on_failure': True,
                    # 2026-10-05 archive incident: the serial-port check
                    # above would NOT have caught that incident's actual
                    # failure (receiver/serial port was fine - the File
                    # service that writes serial data to disk was
                    # stopped, so data/ simply stopped growing, silently,
                    # for 4+ days). This checks the newest RAW (not
                    # archived - see gnss_monitor.py's own
                    # _RAW_DATA_SUFFIXES comment for why *.zip is
                    # deliberately excluded) file's age in data_dir
                    # directly. str2str_file writes/appends continuously
                    # while active, so thresholds are in MINUTES
                    # (RAW_DATA_WARNING_MINUTES=30/
                    # RAW_DATA_CRITICAL_MINUTES=120, both module-level
                    # constants in gnss_monitor.py, not configurable
                    # here - unlike data_dir, these aren't something a
                    # station needs to tune per-install).
                    'check_raw_data_freshness': True,
                    'data_dir': '',  # '' = auto-detect from settings.conf
                },
                'temperature': {
                    'enabled': True,
                    'warning_threshold': 70,  # Celsius
                    'critical_threshold': 80
                },
                'cpu': {
                    'enabled': True,
                    'warning_threshold': 80,  # Percent
                    'critical_threshold': 95,
                    'check_interval_seconds': 1
                },
                'memory': {
                    'enabled': True,
                    'warning_threshold': 80,  # Percent
                    'critical_threshold': 90,
                    'check_swap': True
                }
            },
            'notifications': {
                'email': {
                    'enabled': False,
                    'smtp_server': '',
                    'smtp_port': 587,
                    'from_address': '',
                    'smtp_user': '',
                    'to_addresses': [],
                    'use_tls': True
                },
                'telegram': {
                    'enabled': False,
                    'bot_token': '',
                    'chat_id': ''
                }
            }
        }
        
        if self.config_file.exists():
            try:
                with open(self.config_file, 'r') as f:
                    loaded_config = json.load(f)
                # _deep_merge mutates its first argument (default_config) in
                # place and returns None - it does not return a new dict.
                # The merged result lives in default_config itself after
                # this call, not in a captured return value.
                self._deep_merge(default_config, loaded_config)

                # GeoMaxima one-time cleanup: a station whose
                # watchdog_config.json predates bebce2a (which removed
                # str2str_file.service from the default monitored-services
                # list - its lifecycle belongs to Autosurvey, see
                # survey_controller.py's file_service_owned logic) still has
                # it in its SAVED list forever, since _deep_merge replaces
                # (not unions) a list value wholesale from the loaded file -
                # it never removes an entry the current defaults dropped.
                # Confirmed live: enabling Watchdog on such a station
                # started File logging, because the service monitor
                # restarted any configured-but-down service with no way to
                # tell "down on purpose" apart from "crashed" (now also
                # fixed separately via the enabled-state check in
                # ServiceMonitor._check_service()/check() - this cleanup
                # additionally stops it from being monitored at all).
                services = default_config.get('monitors', {}).get('service', {}).get('services')
                if isinstance(services, list) and 'str2str_file.service' in services:
                    services.remove('str2str_file.service')
                    logger.info("Removed str2str_file.service from the saved Watchdog service list - "
                                "its lifecycle is owned by Autosurvey, not Watchdog.")

                if default_config != loaded_config:
                    self._save_config(default_config)
                return default_config
            except Exception as e:
                logger.error(f"Failed to load config: {e}")

        self._save_config(default_config)
        return default_config

    def _save_config(self, config: Dict) -> bool:
        """Save configuration to file"""
        try:
            self.config_file.parent.mkdir(parents=True, exist_ok=True)
            with open(self.config_file, 'w') as f:
                json.dump(config, f, indent=2)
            return True
        except Exception as e:
            logger.error(f"Failed to save config: {e}")
            return False
    
    def get_config(self) -> Dict:
        """Get current configuration"""
        return self.config
    
    def update_config(self, updates: Dict) -> bool:
        """
        Update configuration
        
        Args:
            updates: Dict with configuration updates
            
        Returns:
            True if successful
        """
        try:
            # Deep merge
            self._deep_merge(self.config, updates)
            
            if self._save_config(self.config):
                logger.info("Configuration updated")
                return True
            return False
        except Exception as e:
            logger.error(f"Failed to update config: {e}")
            return False
    
    def _deep_merge(self, base: Dict, updates: Dict):
        """Deep merge two dictionaries"""
        for key, value in updates.items():
            if key in base and isinstance(base[key], dict) and isinstance(value, dict):
                self._deep_merge(base[key], value)
            else:
                base[key] = value
    
    def run_checks(self) -> Dict[str, Any]:
        """
        Run all enabled monitoring checks
        
        Returns:
            Dict with check results and incidents
        """
        if not self.config.get('enabled', False):
            return {'enabled': False, 'message': 'Watchdog is disabled'}
        
        results = {
            'enabled': True,
            'timestamp': datetime.utcnow().isoformat(),
            'checks': {},
            'incidents': []
        }
        
        # Service monitoring
        if self.config['monitors']['service']['enabled']:
            service_result = self._check_services()
            results['checks']['service'] = service_result
            if service_result.get('incidents'):
                results['incidents'].extend(service_result['incidents'])
        
        # Network monitoring
        if self.config['monitors']['network']['enabled']:
            network_result = self._check_network()
            results['checks']['network'] = network_result
            if network_result.get('incidents'):
                results['incidents'].extend(network_result['incidents'])
        
        # Disk monitoring
        if self.config['monitors']['disk']['enabled']:
            disk_result = self._check_disk()
            results['checks']['disk'] = disk_result
            if disk_result.get('incidents'):
                results['incidents'].extend(disk_result['incidents'])
        
        # GNSS monitoring
        if self.config['monitors']['gnss']['enabled']:
            gnss_result = self._check_gnss()
            results['checks']['gnss'] = gnss_result
            if gnss_result.get('incidents'):
                results['incidents'].extend(gnss_result['incidents'])
        
        # Temperature monitoring
        if self.config['monitors']['temperature']['enabled']:
            temp_result = self._check_temperature()
            results['checks']['temperature'] = temp_result
            if temp_result.get('incidents'):
                results['incidents'].extend(temp_result['incidents'])
        
        # CPU monitoring
        if self.config['monitors']['cpu']['enabled']:
            cpu_result = self._check_cpu()
            results['checks']['cpu'] = cpu_result
            if cpu_result.get('incidents'):
                results['incidents'].extend(cpu_result['incidents'])
        
        # Memory monitoring
        if self.config['monitors']['memory']['enabled']:
            memory_result = self._check_memory()
            results['checks']['memory'] = memory_result
            if memory_result.get('incidents'):
                results['incidents'].extend(memory_result['incidents'])
        
        # Log incidents
        if results['incidents']:
            self._log_incidents(results['incidents'])
            
            # Send notifications if configured
            if self.config['notifications']['email']['enabled']:
                self._send_email_notification(results['incidents'])
            
            if self.config['notifications']['telegram']['enabled']:
                self._send_telegram_notification(results['incidents'])
        
        return results
    
    def _check_services(self) -> Dict:
        """Check RTKBase services status"""
        from .monitors.service_monitor import ServiceMonitor
        
        if not self._service_monitor:
            self._service_monitor = ServiceMonitor(self.config['monitors']['service'])
        
        return self._service_monitor.check()
    
    def _check_network(self) -> Dict:
        """Check network connectivity"""
        from .monitors.network_monitor import NetworkMonitor
        
        if not self._network_monitor:
            self._network_monitor = NetworkMonitor(self.config['monitors']['network'])
        
        return self._network_monitor.check()
    
    def _check_disk(self) -> Dict:
        """Check disk space"""
        from .monitors.disk_monitor import DiskMonitor
        
        if not self._disk_monitor:
            self._disk_monitor = DiskMonitor(self.config['monitors']['disk'])
        
        return self._disk_monitor.check()
    
    def _check_gnss(self) -> Dict:
        """Check GNSS receiver"""
        from .monitors.gnss_monitor import GNSSMonitor
        
        if not self._gnss_monitor:
            self._gnss_monitor = GNSSMonitor(self.config['monitors']['gnss'])
        
        return self._gnss_monitor.check()
    
    def _check_temperature(self) -> Dict:
        """Check system temperature"""
        from .monitors.temperature_monitor import TemperatureMonitor
        
        if not self._temperature_monitor:
            self._temperature_monitor = TemperatureMonitor(self.config['monitors']['temperature'])
        
        return self._temperature_monitor.check()
    
    def _check_cpu(self) -> Dict:
        """Check CPU usage"""
        from .monitors.cpu_monitor import CPUMonitor
        
        if not self._cpu_monitor:
            self._cpu_monitor = CPUMonitor(self.config['monitors']['cpu'])
        
        return self._cpu_monitor.check()
    
    def _check_memory(self) -> Dict:
        """Check memory usage"""
        from .monitors.memory_monitor import MemoryMonitor
        
        if not self._memory_monitor:
            self._memory_monitor = MemoryMonitor(self.config['monitors']['memory'])
        
        return self._memory_monitor.check()
    
    def _log_incidents(self, incidents: List[Dict]):
        """Log incidents to file"""
        try:
            # Load existing incidents
            existing = []
            if self.incident_log_file.exists():
                with open(self.incident_log_file, 'r') as f:
                    existing = json.load(f)
            
            # Add new incidents
            for incident in incidents:
                incident['logged_at'] = datetime.utcnow().isoformat()
                existing.append(incident)
            
            # Keep only last 1000 incidents
            existing = existing[-1000:]
            
            # Save
            with open(self.incident_log_file, 'w') as f:
                json.dump(existing, f, indent=2)
            
        except Exception as e:
            logger.error(f"Failed to log incidents: {e}")
    
    def get_incidents(self, limit: int = 100) -> List[Dict]:
        """Get recent incidents"""
        try:
            if self.incident_log_file.exists():
                with open(self.incident_log_file, 'r') as f:
                    incidents = json.load(f)
                return incidents[-limit:]
            return []
        except Exception as e:
            logger.error(f"Failed to read incidents: {e}")
            return []
    
    def _send_email_notification(self, incidents: List[Dict]):
        """Send email notification"""
        from features.watchdog.notifiers import EmailNotifier
        
        email_config = self.config.get('notifications', {}).get('email', {})
        if not email_config.get('enabled', False):
            return
        
        notifier = EmailNotifier(email_config)
        notifier.send(incidents)
    
    def _send_telegram_notification(self, incidents: List[Dict]):
        """Send Telegram notification"""
        from features.watchdog.notifiers import TelegramNotifier
        
        telegram_config = self.config.get('notifications', {}).get('telegram', {})
        if not telegram_config.get('enabled', False):
            return
        
        notifier = TelegramNotifier(telegram_config)
        notifier.send(incidents)
    
    def get_status(self) -> Dict:
        """Get current watchdog status"""
        return {
            'enabled': self.config.get('enabled', False),
            'monitors': {
                'service': {
                    'enabled': self.config['monitors']['service']['enabled'],
                    'services_count': len(self.config['monitors']['service']['services'])
                },
                'network': {
                    'enabled': self.config['monitors']['network']['enabled']
                },
                'disk': {
                    'enabled': self.config['monitors']['disk']['enabled']
                },
                'gnss': {
                    'enabled': self.config['monitors']['gnss']['enabled']
                },
                'temperature': {
                    'enabled': self.config['monitors']['temperature']['enabled']
                },
                'cpu': {
                    'enabled': self.config['monitors']['cpu']['enabled']
                },
                'memory': {
                    'enabled': self.config['monitors']['memory']['enabled']
                }
            },
            'recent_incidents': len(self.get_incidents(limit=10)),
            'dns': self._dns_status(),
            'reach': self._reach_status(),
        }

    @staticmethod
    def _reach_status():
        """Last LAN/internet reachability result (written by the network monitor), or None."""
        try:
            return json.loads(Path('/var/lib/rtkbase/network_reach.json').read_text())
        except (OSError, ValueError):
            return None

    @staticmethod
    def _dns_status():
        """Last DNS self-test result (written by the network monitor), or None."""
        try:
            from addons import dns_health
        except ImportError:
            try:
                import dns_health
            except ImportError:
                return None
        return dns_health.load_status()

