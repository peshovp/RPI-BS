"""
Auto Survey-In Feature API
==========================

Flask routes for Auto Survey-In web interface and REST API.
"""

import logging
from flask import Blueprint, render_template, jsonify, request
from flask_login import login_required
from typing import Optional
import socket
from pathlib import Path

from .auto_survey import SurveyController

logger = logging.getLogger(__name__)

# Global survey controller instance
_survey_controller: Optional[SurveyController] = None


def get_survey_controller() -> SurveyController:
    """Get or create survey controller instance"""
    global _survey_controller
    
    if _survey_controller is None:
        # Initialize with AUTO mode - discovers RTKBase paths automatically
        _survey_controller = SurveyController(
            settings_file="/home/peshovp/rtkbase/settings.conf",
            state_file="/var/lib/rtkbase/survey_state.json",
            auto_mode=True  # Enable automatic RTKBase integration
        )
        
        # Try to recover previous survey on startup
        try:
            _survey_controller.recover_survey()
        except Exception as e:
            logger.warning(f"Survey recovery failed: {e}")
    
    return _survey_controller


def register_routes(app, gm_blueprint):
    """Register Auto Survey-In routes to blueprint"""
    
    @gm_blueprint.route('/survey')
    @login_required
    def survey_page():
        """Auto Survey-In control page"""
        try:
            controller = get_survey_controller()
            status = controller.get_status()
            hostname = socket.gethostname()
            
            return render_template('geomaxima/auto_survey.html',
                                 status=status,
                                 feature_enabled=True,
                                 hostname=hostname)
        except Exception as e:
            logger.error(f"Survey page error: {e}", exc_info=True)
            hostname = socket.gethostname()
            return render_template('geomaxima/auto_survey.html',
                                 status={},
                                 feature_enabled=False,
                                 error=str(e),
                                 hostname=hostname)
    
    @gm_blueprint.route('/api/survey/status')
    @login_required
    def survey_status():
        """Get current survey status"""
        try:
            controller = get_survey_controller()
            status = controller.get_status()
            
            # Convert numpy types to Python natives for JSON serialization
            def convert_numpy(obj):
                """Recursively convert numpy types to Python natives"""
                import numpy as np
                if isinstance(obj, dict):
                    return {k: convert_numpy(v) for k, v in obj.items()}
                elif isinstance(obj, list):
                    return [convert_numpy(item) for item in obj]
                elif isinstance(obj, np.integer):
                    return int(obj)
                elif isinstance(obj, np.floating):
                    return float(obj)
                elif isinstance(obj, np.ndarray):
                    return obj.tolist()
                else:
                    return obj
            
            status = convert_numpy(status)
            
            return jsonify({
                'success': True,
                'status': status
            })
        except Exception as e:
            logger.error(f"Status error: {e}", exc_info=True)
            return jsonify({
                'success': False,
                'error': str(e)
            }), 500

    @gm_blueprint.route('/api/survey/geoid', methods=['GET'])
    @login_required
    def geoid_status():
        """Return current geoid model status"""
        try:
            controller = get_survey_controller()
            cfg_path = controller.geoid_config_path
            ggf = None
            if cfg_path.exists():
                import json
                with open(cfg_path, 'r') as f:
                    data = json.load(f)
                ggf = data.get('ggf_path')
            return jsonify({'success': True, 'ggf_path': ggf})
        except Exception as e:
            logger.error(f"Geoid status error: {e}", exc_info=True)
            return jsonify({'success': False, 'error': str(e)}), 500

    @gm_blueprint.route('/api/survey/geoid/upload', methods=['POST'])
    @login_required
    def geoid_upload():
        """Upload GGF geoid file and activate it"""
        try:
            controller = get_survey_controller()
            if 'file' not in request.files:
                return jsonify({'success': False, 'error': 'No file provided'}), 400

            file = request.files['file']
            if file.filename == '':
                return jsonify({'success': False, 'error': 'Empty filename'}), 400

            filename = Path(file.filename).name
            suffix = Path(filename).suffix.lower()
            allowed_ext = {'.bin', '.ggf'}
            allowed_mime = {
                'application/octet-stream',
                'binary/octet-stream',
                'application/x-binary'
            }
            max_size = 5 * 1024 * 1024  # 5 MiB limit to avoid oversized uploads

            if suffix not in allowed_ext:
                return jsonify({'success': False, 'error': 'Invalid file type; must be .bin or .ggf'}), 400

            # Inspect size before saving to avoid storing huge files
            try:
                file.stream.seek(0, 2)
                size = file.stream.tell()
                file.stream.seek(0)
            except Exception:
                size = None

            if size is not None and size > max_size:
                return jsonify({'success': False, 'error': 'File too large; max 5 MiB'}), 400

            mimetype = (file.mimetype or '').lower()
            if mimetype and mimetype not in allowed_mime:
                return jsonify({'success': False, 'error': 'Invalid MIME type'}), 400

            dest_dir = controller.geoid_dir
            dest_dir.mkdir(parents=True, exist_ok=True)
            dest_path = dest_dir / filename
            file.save(dest_path)
            if controller.set_geoid_model(dest_path):
                return jsonify({'success': True, 'ggf_path': str(dest_path)})
            return jsonify({
                'success': False,
                'error': controller.geoid.last_error or 'Failed to load geoid model'
            }), 500
        except Exception as e:
            logger.error(f"Geoid upload error: {e}", exc_info=True)
            return jsonify({'success': False, 'error': str(e)}), 500
    
    @gm_blueprint.route('/api/survey/start', methods=['POST'])
    @login_required
    def survey_start():
        """Start new survey session"""
        try:
            data = request.get_json() or {}
            target_hours = data.get('target_hours', 24)
            
            # Validate target_hours
            if not isinstance(target_hours, (int, float)) or target_hours < 1 or target_hours > 72:
                return jsonify({
                    'success': False,
                    'error': 'Invalid target_hours (must be 1-72)'
                }), 400
            
            controller = get_survey_controller()
            
            if controller.start_survey(int(target_hours)):
                return jsonify({
                    'success': True,
                    'message': f'Survey started ({target_hours}h)'
                })
            else:
                return jsonify({
                    'success': False,
                    'error': 'Failed to start survey (already running or invalid state)'
                }), 400
                
        except Exception as e:
            logger.error(f"Start error: {e}", exc_info=True)
            return jsonify({
                'success': False,
                'error': str(e)
            }), 500
    
    @gm_blueprint.route('/api/survey/stop', methods=['POST'])
    @login_required
    def survey_stop():
        """Stop running survey"""
        try:
            controller = get_survey_controller()
            
            if controller.stop_survey():
                return jsonify({
                    'success': True,
                    'message': 'Survey stopped'
                })
            else:
                return jsonify({
                    'success': False,
                    'error': 'No survey running'
                }), 400
                
        except Exception as e:
            logger.error(f"Stop error: {e}", exc_info=True)
            return jsonify({
                'success': False,
                'error': str(e)
            }), 500
    
    @gm_blueprint.route('/api/survey/reset', methods=['POST'])
    @login_required
    def survey_reset():
        """Reset survey state"""
        try:
            controller = get_survey_controller()
            controller.state.reset_survey()
            
            return jsonify({
                'success': True,
                'message': 'Survey state reset'
            })
            
        except Exception as e:
            logger.error(f"Reset error: {e}", exc_info=True)
            return jsonify({
                'success': False,
                'error': str(e)
            }), 500
    
    @gm_blueprint.route('/api/survey/restart-services', methods=['POST'])
    @login_required
    def restart_services():
        """Force restart RTKBase services after survey completion"""
        try:
            controller = get_survey_controller()
            result = controller.restart_rtkbase_services()
            
            return jsonify({
                'success': result['success'],
                'restarted': result['restarted'],
                'failed': result['failed'],
                'message': f"Restarted {len(result['restarted'])} service(s)"
            })
            
        except Exception as e:
            logger.error(f"Restart services error: {e}", exc_info=True)
            return jsonify({
                'success': False,
                'error': str(e)
            }), 500
    
    @gm_blueprint.route('/api/survey/apply', methods=['POST'])
    @login_required
    def apply_coordinates():
        """Apply surveyed coordinates to RTKBase configuration"""
        try:
            controller = get_survey_controller()
            status = controller.get_status()
            
            logger.info(f"Apply coordinates called. Survey state: {status.get('survey_state')}")
            logger.info(f"Full status keys: {list(status.keys())}")
            
            # Check if survey is completed (handle both 'completed' and 'complete')
            state = status.get('survey_state', '').lower()
            if state not in ['completed', 'complete']:
                logger.warning(f"Survey not completed (state={state})")
                return jsonify({
                    'success': False,
                    'error': f'Survey not completed yet (current state: {status.get("survey_state")})',
                    'current_state': status.get('survey_state')
                }), 400
            
            # Get final position
            position = status.get('final_position')
            if not position:
                # Try current_position as fallback
                position = status.get('current_position')
                logger.info(f"Using current_position: {position}")
                
            if not position:
                logger.error("No position in status!")
                return jsonify({
                    'success': False,
                    'error': 'No position data available'
                }), 400
            
            lat = position['lat']
            lon = position['lon']
            height = position['height']
            
            # Update RTKBase configuration
            logger.info(f"✓ Applying coordinates: {lat:.8f} {lon:.8f} {height:.3f}")
            
            if controller.rtkbase.update_position(lat, lon, height):
                logger.info("✓ RTKBase configuration updated")
                # Mark applied in state for visibility and audit
                controller.state.mark_applied({'lat': lat, 'lon': lon, 'height': height})
                
                # Restart services to apply new coordinates
                logger.info("Restarting RTKBase services...")
                restart_result = controller.restart_rtkbase_services()
                
                return jsonify({
                    'success': True,
                    'message': 'Coordinates applied successfully',
                    'position': {
                        'lat': lat,
                        'lon': lon,
                        'height': height
                    },
                    'services_restarted': restart_result['success']
                })
            else:
                logger.error("✗ Failed to update RTKBase configuration")
                return jsonify({
                    'success': False,
                    'error': 'Failed to update RTKBase configuration'
                }), 500
            
        except Exception as e:
            logger.error(f"Apply coordinates error: {e}", exc_info=True)
            import traceback
            logger.error(traceback.format_exc())
            return jsonify({
                'success': False,
                'error': str(e)
            }), 500
    
    @gm_blueprint.route('/api/survey/position')
    @login_required
    def survey_position():
        """Get current antenna position from RTKBase config"""
        try:
            controller = get_survey_controller()
            position = controller.config.get_current_position()
            
            if position:
                return jsonify({
                    'success': True,
                    'position': position
                })
            else:
                return jsonify({
                    'success': True,
                    'position': None,
                    'message': 'No antenna position configured'
                })
                
        except Exception as e:
            logger.error(f"Position error: {e}", exc_info=True)
            return jsonify({
                'success': False,
                'error': str(e)
            }), 500
    
    logger.info("Auto Survey-In routes registered")
