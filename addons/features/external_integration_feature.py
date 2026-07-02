"""
External Integration Feature
GNSS.NET Caster API Integration for remote base station management

This feature allows RTKBase stations to:
- Register with GNSS.NET central caster
- Report status and health metrics
- Update coordinates automatically after Auto Survey
- Receive configuration from caster
- Enable remote monitoring and management
"""

from flask import render_template, jsonify, request
import logging
import json
import requests
import threading
import time
from pathlib import Path
from datetime import datetime
import configparser

logger = logging.getLogger(__name__)

# Global state for caster connection
caster_state = {
    'connected': False,
    'last_update': None,
    'last_error': None,
    'config': {
        'enabled': False,
        'caster_url': '',
        'api_key': '',
        'station_id': '',
        'update_interval': 300,  # seconds
    }
}

# Background thread for periodic updates
update_thread = None
update_running = False


def load_caster_config():
    """Load GNSS.NET caster configuration from settings.conf"""
    try:
        # Try GeoMaxima config first
        config_file = Path(__file__).parent.parent.parent / 'settings.conf'
        
        if not config_file.exists():
            logger.warning(f"Settings file not found: {config_file}")
            return
        
        config = configparser.ConfigParser()
        config.read(config_file)
        
        if 'caster_api' in config:
            caster_state['config']['enabled'] = config.getboolean('caster_api', 'enabled', fallback=False)
            caster_state['config']['caster_url'] = config.get('caster_api', 'url', fallback='')
            caster_state['config']['api_key'] = config.get('caster_api', 'api_key', fallback='')
            caster_state['config']['station_id'] = config.get('caster_api', 'station_id', fallback='')
            caster_state['config']['update_interval'] = config.getint('caster_api', 'update_interval', fallback=300)
            
            logger.info(f"Loaded caster config: enabled={caster_state['config']['enabled']}, url={caster_state['config']['caster_url']}")
        else:
            logger.info("No [caster_api] section in settings.conf - using defaults")
            
    except Exception as e:
        logger.error(f"Failed to load caster config: {e}")


def save_caster_config():
    """Save GNSS.NET caster configuration to settings.conf"""
    try:
        config_file = Path(__file__).parent.parent.parent / 'settings.conf'
        
        config = configparser.ConfigParser()
        config.read(config_file)
        
        if 'caster_api' not in config:
            config.add_section('caster_api')
        
        config.set('caster_api', 'enabled', str(caster_state['config']['enabled']))
        config.set('caster_api', 'url', caster_state['config']['caster_url'])
        config.set('caster_api', 'api_key', caster_state['config']['api_key'])
        config.set('caster_api', 'station_id', caster_state['config']['station_id'])
        config.set('caster_api', 'update_interval', str(caster_state['config']['update_interval']))
        
        with open(config_file, 'w') as f:
            config.write(f)
        
        logger.info("Saved caster config to settings.conf")
        
    except Exception as e:
        logger.error(f"Failed to save caster config: {e}")
        raise


def get_station_info():
    """Get current station information from RTKBase"""
    try:
        config_file = Path(__file__).parent.parent.parent / 'settings.conf'
        config = configparser.ConfigParser()
        config.read(config_file)
        
        # Get position from settings.conf
        position_str = config.get('main', 'position', fallback='0 0 0')
        position_parts = position_str.strip("'").split()
        
        if len(position_parts) == 3:
            lat = float(position_parts[0])
            lon = float(position_parts[1])
            height = float(position_parts[2])
        else:
            lat, lon, height = 0.0, 0.0, 0.0
        
        # Get other settings
        com_port = config.get('main', 'com_port', fallback='')
        com_port_settings = config.get('main', 'com_port_settings', fallback='')
        ntrip_mount = config.get('ntrip', 'ntrip_mount', fallback='')
        
        return {
            'station_id': caster_state['config']['station_id'],
            'position': {
                'lat': lat,
                'lon': lon,
                'height': height
            },
            'receiver': {
                'port': com_port,
                'settings': com_port_settings
            },
            'ntrip': {
                'mountpoint': ntrip_mount
            },
            'timestamp': datetime.utcnow().isoformat() + 'Z'
        }
        
    except Exception as e:
        logger.error(f"Failed to get station info: {e}")
        return None


def send_status_update():
    """Send status update to GNSS.NET caster"""
    if not caster_state['config']['enabled']:
        return False
    
    if not caster_state['config']['caster_url'] or not caster_state['config']['api_key']:
        logger.warning("Caster URL or API key not configured")
        return False
    
    try:
        station_info = get_station_info()
        if not station_info:
            return False
        
        # Add health metrics
        # TODO: Get real metrics from system monitoring
        station_info['health'] = {
            'status': 'online',
            'uptime_seconds': 0,
            'cpu_usage': 0,
            'memory_usage': 0,
            'disk_usage': 0,
            'rtcm_rate': 0
        }
        
        # Send to caster API
        url = f"{caster_state['config']['caster_url']}/api/stations/{caster_state['config']['station_id']}/status"
        headers = {
            'Authorization': f"Bearer {caster_state['config']['api_key']}",
            'Content-Type': 'application/json'
        }
        
        logger.info(f"Sending status update to {url}")
        response = requests.post(url, json=station_info, headers=headers, timeout=10)
        
        if response.status_code == 200:
            caster_state['connected'] = True
            caster_state['last_update'] = datetime.utcnow().isoformat() + 'Z'
            caster_state['last_error'] = None
            logger.info("Status update sent successfully")
            return True
        else:
            error_msg = f"HTTP {response.status_code}: {response.text}"
            caster_state['connected'] = False
            caster_state['last_error'] = error_msg
            logger.error(f"Failed to send status: {error_msg}")
            return False
            
    except Exception as e:
        error_msg = str(e)
        caster_state['connected'] = False
        caster_state['last_error'] = error_msg
        logger.error(f"Failed to send status update: {e}")
        return False


def update_loop():
    """Background thread for periodic status updates"""
    global update_running
    
    logger.info("Caster update loop started")
    
    while update_running:
        try:
            if caster_state['config']['enabled']:
                send_status_update()
            
            # Sleep for update interval
            interval = caster_state['config']['update_interval']
            time.sleep(interval)
            
        except Exception as e:
            logger.error(f"Error in update loop: {e}")
            time.sleep(60)  # Sleep 1 min on error


def start_update_thread():
    """Start background update thread"""
    global update_thread, update_running
    
    if update_thread and update_thread.is_alive():
        logger.info("Update thread already running")
        return
    
    update_running = True
    update_thread = threading.Thread(target=update_loop, daemon=True)
    update_thread.start()
    logger.info("Update thread started")


def stop_update_thread():
    """Stop background update thread"""
    global update_running
    
    update_running = False
    logger.info("Update thread stopped")


def register_routes(app, gm_blueprint):
    """Register External Integration routes"""
    
    # Load config on startup
    load_caster_config()
    
    # Start update thread if enabled
    if caster_state['config']['enabled']:
        start_update_thread()
    
    
    @gm_blueprint.route('/integration')
    def integration_page():
        """GNSS.NET Caster Integration configuration page"""
        try:
            import socket
            hostname = socket.gethostname()
            
            return render_template(
                'geomaxima/external_integration.html',
                feature_enabled=True,
                hostname=hostname,
                config=caster_state['config'],
                state=caster_state
            )
        except Exception as e:
            logger.error(f"Integration page error: {e}")
            return render_template(
                'geomaxima/external_integration.html',
                feature_enabled=False,
                error=str(e)
            )
    
    
    @gm_blueprint.route('/api/integration/config', methods=['GET'])
    def api_get_config():
        """Get GNSS.NET caster configuration"""
        try:
            # Don't expose API key in response
            config_safe = caster_state['config'].copy()
            if config_safe['api_key']:
                config_safe['api_key'] = '***' * 10
            
            return jsonify({
                'success': True,
                'config': config_safe,
                'state': {
                    'connected': caster_state['connected'],
                    'last_update': caster_state['last_update'],
                    'last_error': caster_state['last_error']
                }
            })
            
        except Exception as e:
            logger.error(f"Failed to get config: {e}")
            return jsonify({'success': False, 'error': str(e)}), 500
    
    
    @gm_blueprint.route('/api/integration/config', methods=['POST'])
    def api_update_config():
        """Update GNSS.NET caster configuration"""
        try:
            data = request.get_json() or {}
            
            # Update config
            if 'enabled' in data:
                caster_state['config']['enabled'] = bool(data['enabled'])
            
            if 'caster_url' in data:
                caster_state['config']['caster_url'] = data['caster_url'].strip()
            
            if 'api_key' in data and data['api_key'] != '***' * 10:
                caster_state['config']['api_key'] = data['api_key'].strip()
            
            if 'station_id' in data:
                caster_state['config']['station_id'] = data['station_id'].strip()
            
            if 'update_interval' in data:
                caster_state['config']['update_interval'] = int(data['update_interval'])
            
            # Save to settings.conf
            save_caster_config()
            
            # Restart update thread if enabled
            if caster_state['config']['enabled']:
                start_update_thread()
            else:
                stop_update_thread()
            
            logger.info("Caster configuration updated")
            
            return jsonify({
                'success': True,
                'message': 'Configuration saved successfully'
            })
            
        except Exception as e:
            logger.error(f"Failed to update config: {e}")
            return jsonify({'success': False, 'error': str(e)}), 500
    
    
    @gm_blueprint.route('/api/integration/test', methods=['POST'])
    def api_test_connection():
        """Test connection to GNSS.NET caster"""
        try:
            # Send immediate status update
            success = send_status_update()
            
            if success:
                return jsonify({
                    'success': True,
                    'message': 'Connection test successful',
                    'last_update': caster_state['last_update']
                })
            else:
                return jsonify({
                    'success': False,
                    'error': caster_state['last_error'] or 'Connection failed'
                }), 500
            
        except Exception as e:
            logger.error(f"Connection test failed: {e}")
            return jsonify({'success': False, 'error': str(e)}), 500
    
    
    @gm_blueprint.route('/api/integration/position', methods=['POST'])
    def api_update_position():
        """
        Update position on GNSS.NET caster
        Called automatically after Auto Survey completion
        """
        try:
            if not caster_state['config']['enabled']:
                return jsonify({
                    'success': False,
                    'error': 'Caster integration not enabled'
                }), 400
            
            # Send updated position to caster
            success = send_status_update()
            
            if success:
                return jsonify({
                    'success': True,
                    'message': 'Position updated on caster'
                })
            else:
                return jsonify({
                    'success': False,
                    'error': caster_state['last_error'] or 'Update failed'
                }), 500
            
        except Exception as e:
            logger.error(f"Position update failed: {e}")
            return jsonify({'success': False, 'error': str(e)}), 500
    
    
    logger.info("External Integration (GNSS.NET Caster) routes registered")
