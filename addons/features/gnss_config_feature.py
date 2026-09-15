"""
GNSS Receiver Configuration Manager Feature
Web interface for configuring ZED-F9P, Mosaic-X5, UM980/UM982
"""

import json
import logging
import subprocess
import time
from flask import Blueprint, render_template, request, jsonify, send_file
from pathlib import Path

from .gnss_config.config_manager import ReceiverDetector, GNSSConfigManager
from .gnss_config.zedf9p_config import ZEDF9PConfigurator
from .gnss_config.mosaic_config import MosaicX5Configurator
from .gnss_config.unicore_config import UnicoreConfigurator

logger = logging.getLogger(__name__)

# Create blueprint
gnss_config_bp = Blueprint(
    'gnss_config',
    __name__,
    url_prefix='/gnss-config'
)

# Initialize managers
config_manager = GNSSConfigManager()

# RTKBase services that may use the GNSS port
RTKBASE_SERVICES = [
    'str2str_tcp',
    'str2str_file',
    'str2str_ntrip_A',
    'str2str_ntrip_B',
    'str2str_rtcm_svr',
    'str2str_rtcm_serial',
    'rtkbase_raw2nmea'
]


def stop_rtkbase_services():
    """Stop RTKBase services that may be using the GNSS port"""
    stopped = []
    for service in RTKBASE_SERVICES:
        try:
            result = subprocess.run(
                ['systemctl', 'is-active', service],
                capture_output=True,
                text=True,
                timeout=5
            )
            if result.stdout.strip() == 'active':
                subprocess.run(['sudo', 'systemctl', 'stop', service], timeout=10)
                stopped.append(service)
                logger.info(f"Stopped {service}")
        except Exception as e:
            logger.warning(f"Failed to stop {service}: {e}")
    return stopped


def start_rtkbase_services(services):
    """Restart previously stopped RTKBase services"""
    for service in services:
        try:
            subprocess.run(['sudo', 'systemctl', 'start', service], timeout=10)
            logger.info(f"Restarted {service}")
        except Exception as e:
            logger.error(f"Failed to restart {service}: {e}")


def register_routes(app, gm_blueprint):
    """Register GNSS configuration routes"""
    gm_blueprint.register_blueprint(gnss_config_bp)
    logger.info("✓ GNSS Configuration routes registered")


@gnss_config_bp.route('/')
def index():
    """GNSS Configuration main page"""
    import socket
    hostname = socket.gethostname()
    
    return render_template(
        'geomaxima/gnss_config.html',
        hostname=hostname,
        page_title='GNSS Configuration'
    )


@gnss_config_bp.route('/api/scan', methods=['POST'])
def scan_receivers():
    """Scan for connected GNSS receivers"""
    
    # Get stop_services parameter (default: true)
    data = request.get_json() or {}
    should_stop_services = data.get('stop_services', True)
    
    stopped_services = []
    
    try:
        # Stop RTKBase services if requested
        if should_stop_services:
            logger.info("Stopping RTKBase services to free GNSS port...")
            stopped_services = stop_rtkbase_services()
            if stopped_services:
                logger.info(f"Stopped services: {', '.join(stopped_services)}")
        
        detector = ReceiverDetector()
        ports = config_manager.scan_ports()
        
        if not ports:
            return jsonify({
                'success': False,
                'message': 'No serial ports found',
                'receivers': [],
                'stopped_services': stopped_services
            })
        
        receivers = []
        for port in ports:
            logger.info(f"Scanning {port}...")
            result = detector.detect(port)
            
            if result:
                receivers.append({
                    'port': port,
                    'type': result['type'],
                    'firmware': result.get('version', 'Unknown'),
                    'baudrate': result.get('baudrate', 115200)
                })
        
        return jsonify({
            'success': True,
            'receivers': receivers,
            'message': f'Found {len(receivers)} receiver(s)',
            'stopped_services': stopped_services
        })
        
    except Exception as e:
        logger.error(f"Scan failed: {e}")
        # Try to restart services even if scan failed
        if stopped_services:
            start_rtkbase_services(stopped_services)
        return jsonify({
            'success': False,
            'message': str(e),
            'receivers': [],
            'stopped_services': []
        }), 500
    
    finally:
        # Always restart services after scan
        if stopped_services:
            logger.info("Restarting RTKBase services...")
            start_rtkbase_services(stopped_services)


@gnss_config_bp.route('/api/restart-services', methods=['POST'])
def restart_services():
    """Manually restart RTKBase services"""
    try:
        data = request.get_json() or {}
        services = data.get('services', RTKBASE_SERVICES)
        
        restarted = []
        for service in services:
            try:
                subprocess.run(['sudo', 'systemctl', 'restart', service], timeout=10)
                restarted.append(service)
                logger.info(f"Restarted {service}")
            except Exception as e:
                logger.warning(f"Failed to restart {service}: {e}")
        
        return jsonify({
            'success': True,
            'message': f'Restarted {len(restarted)} service(s)',
            'restarted': restarted
        })
    
    except Exception as e:
        logger.error(f"Restart services failed: {e}")
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@gnss_config_bp.route('/api/info/<path:port>', methods=['GET'])
def get_receiver_info(port):
    """Get detailed receiver information"""
    try:
        detector = ReceiverDetector()
        result = detector.detect(port)
        
        if not result:
            return jsonify({
                'success': False,
                'message': f'No receiver detected on {port}'
            }), 404
        
        return jsonify({
            'success': True,
            'info': result
        })
        
    except Exception as e:
        logger.error(f"Get info failed: {e}")
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@gnss_config_bp.route('/api/configure', methods=['POST'])
def configure_receiver():
    """Apply configuration to receiver"""
    try:
        data = request.json
        
        port = data.get('port')
        receiver_type = data.get('type')
        baudrate = data.get('baudrate', 115200)
        config = data.get('config', {})
        
        if not port or not receiver_type:
            return jsonify({
                'success': False,
                'message': 'Missing port or receiver type'
            }), 400
        
        # Create configurator
        configurator = None
        if receiver_type == 'ZED-F9P':
            configurator = ZEDF9PConfigurator(port, baudrate)
        elif receiver_type == 'Mosaic-X5':
            configurator = MosaicX5Configurator(port, baudrate)
        elif receiver_type in ['UM980', 'UM982']:
            configurator = UnicoreConfigurator(port, baudrate)
        else:
            return jsonify({
                'success': False,
                'message': f'Unsupported receiver type: {receiver_type}'
            }), 400
        
        # Connect
        if not configurator.connect():
            return jsonify({
                'success': False,
                'message': 'Failed to connect to receiver'
            }), 500
        
        try:
            results = []
            is_unicore = isinstance(configurator, UnicoreConfigurator)

            # --- Unicore (UM980/UM982)-only steps, run FIRST ---
            # set_signal_group_preset() sends "CONFIG SIGNALGROUP {n}",
            # which this project's own receiver_cfg/Unicore_UM980_rtcm3.cfg
            # documents as resetting the device - so it must run before any
            # other config step, or a reset afterward would silently
            # discard everything sent before it. All other config steps
            # below (existing and new) come after this block.
            #
            # Opt-in via 'signal_group_preset' config key, not applied
            # unconditionally to every UM980 configure call - this changes
            # which GNSS bands are tracked (see unicore_config.py's
            # docstring) and resets the receiver, which is more disruptive
            # than the pre-existing steps below.
            if is_unicore and 'signal_group_preset' in config:
                preset = config['signal_group_preset']

                if configurator.set_signal_group_preset(preset):
                    results.append(f'✓ Signal group preset: {preset}')

                    # Reset behavior after "CONFIG SIGNALGROUP" is NOT
                    # documented anywhere in this codebase (confirmed -
                    # reset_receiver() below has no reconnect logic
                    # either, so there's no existing precedent to follow)
                    # and was NOT live-tested this session against a real
                    # UM980. Defensive reconnect: whether the reset drops
                    # the serial port (closing it) or just reboots the
                    # receiver logically while keeping the UART link up,
                    # this handles both without assuming either - a brief
                    # settle delay, then reconnect if the port dropped,
                    # with a couple of retries since a receiver reboot can
                    # take longer than a single reconnect attempt to
                    # complete.
                    time.sleep(2.0)
                    if not configurator.serial or not configurator.serial.is_open:
                        reconnected = False
                        for attempt in range(3):
                            if configurator.connect():
                                reconnected = True
                                break
                            time.sleep(1.0)
                        if reconnected:
                            results.append('✓ Reconnected after signal group reset')
                        else:
                            results.append('✗ Failed to reconnect after signal group reset - remaining steps skipped')
                            configurator.disconnect()
                            return jsonify({
                                'success': False,
                                'message': 'Receiver did not come back after signal group preset reset',
                                'results': results
                            }), 500
                else:
                    results.append('✗ Signal group preset failed')

            if is_unicore and 'sbas_enabled' in config:
                if configurator.set_sbas_enabled(config['sbas_enabled']):
                    results.append(f"✓ SBAS: {'enabled' if config['sbas_enabled'] else 'disabled'}")
                else:
                    results.append('✗ SBAS configuration failed')

            if is_unicore and 'rtcm_clock_offset_enabled' in config:
                if configurator.set_rtcm_clock_offset(config['rtcm_clock_offset_enabled']):
                    results.append(f"✓ RTCM clock offset: {'enabled' if config['rtcm_clock_offset_enabled'] else 'disabled'}")
                else:
                    results.append('✗ RTCM clock offset configuration failed')

            if is_unicore and 'undulation_m' in config:
                if configurator.set_undulation(config['undulation_m']):
                    results.append(f"✓ Undulation: {config['undulation_m']}m")
                else:
                    results.append('✗ Undulation configuration failed')

            if is_unicore and 'base_antenna_model' in config:
                antenna_params = config['base_antenna_model'] if isinstance(config['base_antenna_model'], dict) else {}
                if configurator.set_base_antenna_model(**antenna_params):
                    results.append('✓ Base antenna model configured')
                else:
                    results.append('✗ Base antenna model configuration failed')

            if is_unicore and 'rtcm_snr_mask' in config:
                mask_params = config['rtcm_snr_mask'] if isinstance(config['rtcm_snr_mask'], dict) else {}
                if configurator.set_rtcm_snr_mask(**mask_params):
                    results.append('✓ RTCM SNR mask configured')
                else:
                    results.append('✗ RTCM SNR mask configuration failed')

            # Configure RTCM messages
            if 'rtcm_messages' in config:
                messages = config['rtcm_messages']
                rate = config.get('rtcm_rate', 1.0)
                
                if configurator.set_rtcm_messages(messages, rate):
                    results.append(f'✓ RTCM messages configured')
                else:
                    results.append('✗ RTCM configuration failed')
            
            # Configure base mode
            if 'base_mode' in config:
                mode = config['base_mode']
                mode_params = config.get('base_params', {})
                
                if configurator.set_base_mode(mode, **mode_params):
                    results.append(f'✓ Base mode: {mode}')
                else:
                    results.append(f'✗ Base mode configuration failed')
            
            # Additional settings
            if 'elevation_mask' in config:
                angle = config['elevation_mask']
                if configurator.set_elevation_mask(angle):
                    results.append(f'✓ Elevation mask: {angle}°')
            
            # Save configuration
            if config.get('save_to_flash', False):
                if configurator.save_config():
                    results.append('✓ Configuration saved to flash')
                else:
                    results.append('✗ Save to flash failed')
            
            configurator.disconnect()
            
            return jsonify({
                'success': True,
                'message': 'Configuration applied',
                'results': results
            })
            
        except Exception as e:
            configurator.disconnect()
            raise e
        
    except Exception as e:
        logger.error(f"Configure failed: {e}")
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@gnss_config_bp.route('/api/profiles', methods=['GET'])
def list_profiles():
    """List all saved profiles"""
    try:
        receiver_type = request.args.get('type')
        profiles = config_manager.list_profiles(receiver_type)
        
        return jsonify({
            'success': True,
            'profiles': profiles
        })
        
    except Exception as e:
        logger.error(f"List profiles failed: {e}")
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@gnss_config_bp.route('/api/profiles', methods=['POST'])
def save_profile():
    """Save configuration profile"""
    try:
        data = request.json
        
        name = data.get('name')
        receiver_type = data.get('type')
        config = data.get('config')
        
        if not name or not receiver_type or not config:
            return jsonify({
                'success': False,
                'message': 'Missing required fields'
            }), 400
        
        if config_manager.save_profile(name, receiver_type, config):
            return jsonify({
                'success': True,
                'message': f'Profile "{name}" saved'
            })
        else:
            return jsonify({
                'success': False,
                'message': 'Failed to save profile'
            }), 500
        
    except Exception as e:
        logger.error(f"Save profile failed: {e}")
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@gnss_config_bp.route('/api/profiles/<name>', methods=['DELETE'])
def delete_profile(name):
    """Delete configuration profile"""
    try:
        if config_manager.delete_profile(name):
            return jsonify({
                'success': True,
                'message': f'Profile "{name}" deleted'
            })
        else:
            return jsonify({
                'success': False,
                'message': 'Profile not found'
            }), 404
        
    except Exception as e:
        logger.error(f"Delete profile failed: {e}")
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@gnss_config_bp.route('/api/profiles/<name>/load', methods=['GET'])
def load_profile(name):
    """Load configuration profile"""
    try:
        profile = config_manager.load_profile(name)
        
        if profile:
            return jsonify({
                'success': True,
                'profile': profile
            })
        else:
            return jsonify({
                'success': False,
                'message': 'Profile not found'
            }), 404
        
    except Exception as e:
        logger.error(f"Load profile failed: {e}")
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@gnss_config_bp.route('/api/import', methods=['POST'])
def import_profile():
    """Import profile from uploaded file"""
    try:
        if 'file' not in request.files:
            return jsonify({
                'success': False,
                'message': 'No file uploaded'
            }), 400
        
        file = request.files['file']
        if file.filename == '':
            return jsonify({
                'success': False,
                'message': 'No file selected'
            }), 400
        
        # Read and parse file
        content = file.read().decode('utf-8')
        profile_data = json.loads(content)
        
        # Save profile
        name = profile_data.get('name', file.filename.replace('.json', ''))
        receiver_type = profile_data.get('receiver_type')
        config = profile_data.get('config')
        
        if config_manager.save_profile(name, receiver_type, config):
            return jsonify({
                'success': True,
                'message': f'Profile "{name}" imported'
            })
        else:
            return jsonify({
                'success': False,
                'message': 'Failed to import profile'
            }), 500
        
    except Exception as e:
        logger.error(f"Import failed: {e}")
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@gnss_config_bp.route('/api/export/<name>', methods=['GET'])
def export_profile(name):
    """Export profile to downloadable file"""
    try:
        profile = config_manager.load_profile(name)
        
        if not profile:
            return jsonify({
                'success': False,
                'message': 'Profile not found'
            }), 404
        
        # Create temporary file
        import tempfile
        fd, path = tempfile.mkstemp(suffix='.json')
        
        with open(path, 'w') as f:
            json.dump(profile, f, indent=2)
        
        return send_file(
            path,
            as_attachment=True,
            download_name=f'{name}.json',
            mimetype='application/json'
        )
        
    except Exception as e:
        logger.error(f"Export failed: {e}")
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500
