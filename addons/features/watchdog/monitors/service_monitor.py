"""
Service Monitor - Monitor and auto-restart RTKBase services
"""

import logging
import subprocess
import json
from typing import Dict, List
from datetime import datetime, timedelta
from pathlib import Path

logger = logging.getLogger(__name__)


class ServiceMonitor:
    """Monitor systemd services and auto-restart on failure"""
    
    def __init__(self, config: Dict):
        """
        Initialize service monitor
        
        Args:
            config: Service monitor configuration
        """
        self.config = config
        self.restart_history_file = Path("/var/lib/rtkbase/service_restart_history.json")
        self.restart_history = self._load_restart_history()
    
    def _load_restart_history(self) -> Dict:
        """Load restart history from file"""
        if self.restart_history_file.exists():
            try:
                with open(self.restart_history_file, 'r') as f:
                    return json.load(f)
            except:
                pass
        return {}
    
    def _save_restart_history(self):
        """Save restart history to file"""
        try:
            self.restart_history_file.parent.mkdir(parents=True, exist_ok=True)
            with open(self.restart_history_file, 'w') as f:
                json.dump(self.restart_history, f, indent=2)
        except Exception as e:
            logger.error(f"Failed to save restart history: {e}")
    
    def check(self) -> Dict:
        """
        Check all configured services
        
        Returns:
            Dict with service status and incidents
        """
        results = {
            'status': 'ok',
            'services': {},
            'incidents': []
        }
        
        for service_name in self.config.get('services', []):
            service_status = self._check_service(service_name)
            results['services'][service_name] = service_status
            
            if not service_status['active']:
                results['status'] = 'warning'
                
                # Attempt auto-restart if enabled
                if self.config.get('auto_restart', False):
                    if self._should_restart(service_name):
                        restart_success = self._restart_service(service_name)
                        
                        if restart_success:
                            results['incidents'].append({
                                'type': 'service_restarted',
                                'severity': 'warning',
                                'service': service_name,
                                'message': f'Service {service_name} was down and has been restarted',
                                'timestamp': datetime.utcnow().isoformat()
                            })
                        else:
                            results['status'] = 'critical'
                            results['incidents'].append({
                                'type': 'service_restart_failed',
                                'severity': 'critical',
                                'service': service_name,
                                'message': f'Service {service_name} is down and restart failed',
                                'timestamp': datetime.utcnow().isoformat()
                            })
                    else:
                        results['incidents'].append({
                            'type': 'service_down',
                            'severity': 'warning',
                            'service': service_name,
                            'message': f'Service {service_name} is down (restart limit reached or in cooldown)',
                            'timestamp': datetime.utcnow().isoformat()
                        })
                else:
                    results['incidents'].append({
                        'type': 'service_down',
                        'severity': 'warning',
                        'service': service_name,
                        'message': f'Service {service_name} is down (auto-restart disabled)',
                        'timestamp': datetime.utcnow().isoformat()
                    })
        
        return results
    
    def _check_service(self, service_name: str) -> Dict:
        """
        Check if service is active
        
        Args:
            service_name: Systemd service name
            
        Returns:
            Dict with service status
        """
        try:
            # Check if service is active
            result = subprocess.run(
                ['systemctl', 'is-active', service_name],
                capture_output=True,
                text=True
            )
            
            is_active = result.stdout.strip() == 'active'
            
            # Get service status details
            status_result = subprocess.run(
                ['systemctl', 'status', service_name, '--no-pager'],
                capture_output=True,
                text=True
            )
            
            return {
                'active': is_active,
                'status': result.stdout.strip(),
                'details': status_result.stdout
            }
            
        except Exception as e:
            logger.error(f"Failed to check service {service_name}: {e}")
            return {
                'active': False,
                'status': 'unknown',
                'error': str(e)
            }
    
    def _should_restart(self, service_name: str) -> bool:
        """
        Check if service should be restarted based on limits and cooldown
        
        Args:
            service_name: Service to check
            
        Returns:
            True if restart should be attempted
        """
        now = datetime.utcnow()
        max_attempts = self.config.get('max_restart_attempts', 3)
        cooldown_seconds = self.config.get('restart_cooldown_seconds', 300)
        
        if service_name not in self.restart_history:
            self.restart_history[service_name] = {
                'attempts': 0,
                'last_restart': None,
                'window_start': now.isoformat()
            }
        
        service_history = self.restart_history[service_name]
        
        # Check cooldown
        if service_history['last_restart']:
            last_restart = datetime.fromisoformat(service_history['last_restart'])
            if (now - last_restart).total_seconds() < cooldown_seconds:
                return False
        
        # Reset counter if window expired (1 hour)
        window_start = datetime.fromisoformat(service_history['window_start'])
        if (now - window_start).total_seconds() > 3600:
            service_history['attempts'] = 0
            service_history['window_start'] = now.isoformat()
        
        # Check attempt limit
        if service_history['attempts'] >= max_attempts:
            return False
        
        return True
    
    def _restart_service(self, service_name: str) -> bool:
        """
        Restart a service
        
        Args:
            service_name: Service to restart
            
        Returns:
            True if restart successful
        """
        try:
            logger.info(f"Attempting to restart {service_name}...")
            
            result = subprocess.run(
                ['sudo', 'systemctl', 'restart', service_name],
                capture_output=True,
                text=True,
                timeout=30
            )
            
            if result.returncode == 0:
                # Update restart history
                now = datetime.utcnow()
                if service_name not in self.restart_history:
                    self.restart_history[service_name] = {
                        'attempts': 0,
                        'window_start': now.isoformat()
                    }
                
                self.restart_history[service_name]['attempts'] += 1
                self.restart_history[service_name]['last_restart'] = now.isoformat()
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
        """Get service restart history"""
        return self.restart_history
    
    def reset_restart_counter(self, service_name: str):
        """Reset restart counter for a service"""
        if service_name in self.restart_history:
            self.restart_history[service_name]['attempts'] = 0
            self.restart_history[service_name]['window_start'] = datetime.utcnow().isoformat()
            self._save_restart_history()
