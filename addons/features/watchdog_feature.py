"""
Watchdog Feature - Flask Blueprint
"""

import logging
import socket
from flask import Blueprint, render_template, jsonify, request
from .watchdog.watchdog_controller import WatchdogController

logger = logging.getLogger(__name__)

# Create blueprint
watchdog_bp = Blueprint('watchdog', __name__, url_prefix='/geomaxima/watchdog')

# Initialize controller
watchdog_controller = WatchdogController()


def register_routes(app, gm_blueprint):
    """Register Watchdog routes"""
    # Register routes defined below
    app.register_blueprint(watchdog_bp)
    logger.info("Watchdog routes registered")


@watchdog_bp.route('/')
def index():
    """Watchdog dashboard"""
    try:
        status = watchdog_controller.get_status()
        config = watchdog_controller.get_config()
        recent_incidents = watchdog_controller.get_incidents(limit=20)
        
        hostname = socket.gethostname()
        
        return render_template(
            'geomaxima/watchdog.html',
            status=status,
            config=config,
            recent_incidents=recent_incidents,
            hostname=hostname
        )
    except Exception as e:
        logger.error(f"Watchdog page error: {e}", exc_info=True)
        return render_template('geomaxima/watchdog.html', error=str(e))


# API Endpoints

@watchdog_bp.route('/api/status', methods=['GET'])
def api_get_status():
    """Get watchdog status"""
    try:
        status = watchdog_controller.get_status()
        return jsonify({'success': True, 'status': status})
    except Exception as e:
        logger.error(f"Get status error: {e}")
        return jsonify({'success': False, 'error': str(e)}), 500


@watchdog_bp.route('/api/config', methods=['GET'])
def api_get_config():
    """Get watchdog configuration"""
    try:
        config = watchdog_controller.get_config()
        return jsonify({'success': True, 'config': config})
    except Exception as e:
        logger.error(f"Get config error: {e}")
        return jsonify({'success': False, 'error': str(e)}), 500


@watchdog_bp.route('/api/config', methods=['POST'])
def api_update_config():
    """Update watchdog configuration"""
    try:
        updates = request.json
        
        if not updates:
            return jsonify({'success': False, 'error': 'No configuration provided'}), 400
        
        success = watchdog_controller.update_config(updates)
        
        if success:
            return jsonify({'success': True, 'message': 'Configuration updated'})
        else:
            return jsonify({'success': False, 'error': 'Failed to save configuration'}), 500
            
    except Exception as e:
        logger.error(f"Update config error: {e}")
        return jsonify({'success': False, 'error': str(e)}), 500


@watchdog_bp.route('/api/run-checks', methods=['POST'])
def api_run_checks():
    """Run all monitoring checks manually"""
    try:
        results = watchdog_controller.run_checks()
        return jsonify({'success': True, 'results': results})
    except Exception as e:
        logger.error(f"Run checks error: {e}")
        return jsonify({'success': False, 'error': str(e)}), 500


@watchdog_bp.route('/api/incidents', methods=['GET'])
def api_get_incidents():
    """Get incident history"""
    try:
        limit = request.args.get('limit', 100, type=int)
        incidents = watchdog_controller.get_incidents(limit=limit)
        return jsonify({'success': True, 'incidents': incidents})
    except Exception as e:
        logger.error(f"Get incidents error: {e}")
        return jsonify({'success': False, 'error': str(e)}), 500


@watchdog_bp.route('/api/toggle-monitor', methods=['POST'])
def api_toggle_monitor():
    """Enable/disable a specific monitor"""
    try:
        data = request.json
        monitor_name = data.get('monitor')
        enabled = data.get('enabled', False)
        
        if not monitor_name:
            return jsonify({'success': False, 'error': 'Monitor name required'}), 400
        
        # Update config
        updates = {
            'monitors': {
                monitor_name: {
                    'enabled': enabled
                }
            }
        }
        
        success = watchdog_controller.update_config(updates)
        
        if success:
            return jsonify({
                'success': True,
                'message': f'Monitor {monitor_name} {"enabled" if enabled else "disabled"}'
            })
        else:
            return jsonify({'success': False, 'error': 'Failed to update configuration'}), 500
            
    except Exception as e:
        logger.error(f"Toggle monitor error: {e}")
        return jsonify({'success': False, 'error': str(e)}), 500


@watchdog_bp.route('/api/toggle-watchdog', methods=['POST'])
def api_toggle_watchdog():
    """Enable/disable entire watchdog system"""
    try:
        data = request.json
        enabled = data.get('enabled', False)
        
        updates = {'enabled': enabled}
        success = watchdog_controller.update_config(updates)
        
        if success:
            return jsonify({
                'success': True,
                'message': f'Watchdog {"enabled" if enabled else "disabled"}'
            })
        else:
            return jsonify({'success': False, 'error': 'Failed to update configuration'}), 500
            
    except Exception as e:
        logger.error(f"Toggle watchdog error: {e}")
        return jsonify({'success': False, 'error': str(e)}), 500


@watchdog_bp.route('/api/test-email', methods=['POST'])
def api_test_email():
    """Test email notification configuration"""
    try:
        from features.watchdog.notifiers import test_email_config
        
        config = request.json
        result = test_email_config(config)
        
        return jsonify(result)
        
    except Exception as e:
        logger.error(f"Test email error: {e}")
        return jsonify({'success': False, 'message': str(e)}), 500


@watchdog_bp.route('/api/test-telegram', methods=['POST'])
def api_test_telegram():
    """Test Telegram notification configuration"""
    try:
        from features.watchdog.notifiers import test_telegram_config
        
        config = request.json
        result = test_telegram_config(config)
        
        return jsonify(result)
        
    except Exception as e:
        logger.error(f"Test telegram error: {e}")
        return jsonify({'success': False, 'message': str(e)}), 500

