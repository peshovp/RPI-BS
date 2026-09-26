"""
WireGuard Client Manager Feature
Full web interface for WireGuard VPN client configuration
"""

from flask import jsonify, request, render_template
import os
import subprocess
import logging
import re
from flask_login import login_required

logger = logging.getLogger(__name__)

# WireGuard configuration paths
WG_CONFIG_DIR = "/etc/wireguard"
WG_INTERFACE = "wg0"
WG_CONFIG_FILE = f"{WG_CONFIG_DIR}/{WG_INTERFACE}.conf"


def register_routes(app, gm_blueprint):
    """Register WireGuard Client routes"""
    
    @gm_blueprint.route('/wireguard')
    @login_required
    def wireguard_ui():
        """WireGuard Client UI page"""
        return render_template('geomaxima/wireguard.html')
    
    @gm_blueprint.route('/api/wireguard/status')
    @login_required
    def get_wireguard_status():
        """Get WireGuard connection status"""
        try:
            # Check if WireGuard is installed
            wg_installed = check_wireguard_installed()
            
            if not wg_installed:
                return jsonify({
                    "status": "not_installed",
                    "installed": False,
                    "message": "WireGuard is not installed"
                })
            
            # Check if config exists
            config_exists = os.path.exists(WG_CONFIG_FILE)
            
            # Check if interface is active
            is_active = False
            is_enabled = False
            connected = False
            endpoint = None
            transfer_rx = None
            transfer_tx = None
            
            if config_exists:
                # Check systemd service status
                try:
                    result = subprocess.run(
                        ['systemctl', 'is-active', f'wg-quick@{WG_INTERFACE}'],
                        capture_output=True, text=True, timeout=5
                    )
                    is_active = result.stdout.strip() == 'active'
                except:
                    pass
                
                # Check if enabled on boot
                try:
                    result = subprocess.run(
                        ['systemctl', 'is-enabled', f'wg-quick@{WG_INTERFACE}'],
                        capture_output=True, text=True, timeout=5
                    )
                    is_enabled = result.stdout.strip() == 'enabled'
                except:
                    pass
                
                # Get connection details if active
                if is_active:
                    try:
                        result = subprocess.run(
                            ['wg', 'show', WG_INTERFACE],
                            capture_output=True, text=True, timeout=5
                        )
                        if result.returncode == 0:
                            wg_output = result.stdout
                            connected = 'peer' in wg_output.lower()
                            
                            # Parse endpoint
                            endpoint_match = re.search(r'endpoint:\s*(\S+)', wg_output)
                            if endpoint_match:
                                endpoint = endpoint_match.group(1)
                            
                            # Parse transfer
                            transfer_match = re.search(r'transfer:\s*(\S+)\s*received,\s*(\S+)\s*sent', wg_output)
                            if transfer_match:
                                transfer_rx = transfer_match.group(1)
                                transfer_tx = transfer_match.group(2)
                    except:
                        pass
            
            return jsonify({
                "status": "ok",
                "installed": True,
                "config_exists": config_exists,
                "is_active": is_active,
                "is_enabled": is_enabled,
                "connected": connected,
                "interface": WG_INTERFACE,
                "endpoint": endpoint,
                "transfer": {
                    "received": transfer_rx,
                    "sent": transfer_tx
                } if transfer_rx else None
            })
            
        except Exception as e:
            logger.error(f"Error getting WireGuard status: {e}")
            return jsonify({"status": "error", "message": str(e)}), 500
    
    @gm_blueprint.route('/api/wireguard/config', methods=['GET'])
    @login_required
    def get_wireguard_config():
        """Get current WireGuard configuration"""
        try:
            if not os.path.exists(WG_CONFIG_FILE):
                return jsonify({
                    "status": "not_found",
                    "message": "Configuration file does not exist"
                }), 404
            
            # Read config file
            with open(WG_CONFIG_FILE, 'r') as f:
                config_content = f.read()
            
            return jsonify({
                "status": "ok",
                "config": config_content,
                "file_path": WG_CONFIG_FILE
            })
            
        except PermissionError:
            return jsonify({
                "status": "error",
                "message": "Permission denied. Run with sudo."
            }), 403
        except Exception as e:
            logger.error(f"Error reading WireGuard config: {e}")
            return jsonify({"status": "error", "message": str(e)}), 500
    
    @gm_blueprint.route('/api/wireguard/config', methods=['POST'])
    @login_required
    def save_wireguard_config():
        """Save WireGuard configuration"""
        try:
            data = request.get_json()
            config_content = data.get('config', '').strip()
            
            if not config_content:
                return jsonify({
                    "status": "error",
                    "message": "Configuration content is empty"
                }), 400
            
            # Validate config format
            if '[Interface]' not in config_content:
                return jsonify({
                    "status": "error",
                    "message": "Invalid WireGuard configuration: [Interface] section missing"
                }), 400
            
            # Create config directory if it doesn't exist
            os.makedirs(WG_CONFIG_DIR, mode=0o700, exist_ok=True)
            
            # Backup existing config if it exists
            if os.path.exists(WG_CONFIG_FILE):
                backup_file = f"{WG_CONFIG_FILE}.backup"
                subprocess.run(['cp', WG_CONFIG_FILE, backup_file], check=False)
            
            # Write new config
            with open(WG_CONFIG_FILE, 'w') as f:
                f.write(config_content)
            
            # Set proper permissions
            os.chmod(WG_CONFIG_FILE, 0o600)
            
            logger.info("WireGuard configuration saved successfully")
            
            return jsonify({
                "status": "ok",
                "message": "Configuration saved successfully"
            })
            
        except PermissionError:
            return jsonify({
                "status": "error",
                "message": "Permission denied. Service must run with sudo."
            }), 403
        except Exception as e:
            logger.error(f"Error saving WireGuard config: {e}")
            return jsonify({"status": "error", "message": str(e)}), 500
    
    @gm_blueprint.route('/api/wireguard/control/<action>', methods=['POST'])
    @login_required
    def control_wireguard(action):
        """Control WireGuard service (start/stop/restart/enable/disable)"""
        try:
            if action not in ['start', 'stop', 'restart', 'enable', 'disable']:
                return jsonify({
                    "status": "error",
                    "message": f"Invalid action: {action}"
                }), 400
            
            service_name = f'wg-quick@{WG_INTERFACE}'
            
            # Execute systemctl command
            result = subprocess.run(
                ['systemctl', action, service_name],
                capture_output=True, text=True, timeout=10
            )
            
            if result.returncode == 0:
                return jsonify({
                    "status": "ok",
                    "message": f"WireGuard {action} successful",
                    "action": action
                })
            else:
                return jsonify({
                    "status": "error",
                    "message": f"Failed to {action} WireGuard: {result.stderr}"
                }), 500
                
        except subprocess.TimeoutExpired:
            return jsonify({
                "status": "error",
                "message": "Command timed out"
            }), 500
        except Exception as e:
            logger.error(f"Error controlling WireGuard: {e}")
            return jsonify({"status": "error", "message": str(e)}), 500
    
    @gm_blueprint.route('/api/wireguard/install', methods=['POST'])
    @login_required
    def install_wireguard():
        """Install WireGuard packages"""
        try:
            # Check if already installed
            if check_wireguard_installed():
                return jsonify({
                    "status": "ok",
                    "message": "WireGuard is already installed"
                })

            result = subprocess.run(
                ['apt-get', 'update'],
                capture_output=True, text=True, timeout=60
            )

            # GeoMaxima: NEVER install the Debian `wireguard` metapackage
            # directly - it depends on wireguard-modules, which only
            # Debian's own linux-image-* kernel packages provide, which
            # would pull in a Debian-origin kernel alongside a board's own
            # vendor kernel (confirmed live on an Orange Pi 4 Pro+: this is
            # almost certainly what originally bricked that station, the
            # same unbootable combination tools/armbian_kernel_pin.sh
            # exists to prevent). Delegates to the single shared helper,
            # tools/wireguard_setup.sh's geomaxima_install_wireguard(),
            # which installs only wireguard-tools, plus wireguard-go if the
            # running kernel lacks native WireGuard support - see that
            # file's header comment for the full "why". Not
            # re-implemented here in Python so install.sh/perform_update.sh/
            # this route can never drift out of sync on which packages are
            # actually installed.
            wireguard_setup_sh = os.path.abspath(os.path.join(
                os.path.dirname(__file__), "..", "..", "tools", "wireguard_setup.sh"
            ))
            result = subprocess.run(
                ['bash', '-c', f'source {wireguard_setup_sh!r} && geomaxima_install_wireguard'],
                capture_output=True, text=True, timeout=120
            )

            if result.returncode == 0 and check_wireguard_installed():
                return jsonify({
                    "status": "ok",
                    "message": "WireGuard installed successfully",
                    "details": result.stdout
                })
            else:
                return jsonify({
                    "status": "error",
                    "message": f"Installation failed: {result.stderr or result.stdout}"
                }), 500

        except Exception as e:
            logger.error(f"Error installing WireGuard: {e}")
            return jsonify({"status": "error", "message": str(e)}), 500
    
    @gm_blueprint.route('/api/wireguard/logs')
    @login_required
    def get_wireguard_logs():
        """Get WireGuard service logs"""
        try:
            result = subprocess.run(
                ['journalctl', '-u', f'wg-quick@{WG_INTERFACE}', '-n', '50', '--no-pager'],
                capture_output=True, text=True, timeout=10
            )
            
            return jsonify({
                "status": "ok",
                "logs": result.stdout
            })
            
        except Exception as e:
            logger.error(f"Error getting WireGuard logs: {e}")
            return jsonify({"status": "error", "message": str(e)}), 500
    
    logger.info("WireGuard Client feature routes registered")


def check_wireguard_installed():
    """Check if WireGuard is installed"""
    try:
        result = subprocess.run(
            ['which', 'wg'],
            capture_output=True, timeout=5
        )
        return result.returncode == 0
    except:
        return False


def initialize(app):
    """Initialize WireGuard feature"""
    logger.info("WireGuard Client feature initialized")
