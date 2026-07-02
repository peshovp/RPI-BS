"""
OTA Update Feature
Web-based update system for remote deployments
"""

from flask import render_template, jsonify, request
import logging
import socket
import threading
from datetime import datetime
from .ota_update import UpdateController

logger = logging.getLogger(__name__)

# Global controller instance
_update_controller = None


def get_update_controller() -> UpdateController:
    """Get or create update controller instance"""
    global _update_controller
    
    if _update_controller is None:
        _update_controller = UpdateController()  # Auto-detects repo path
        logger.info("UpdateController initialized")
    
    return _update_controller


def register_routes(app, gm_blueprint):
    """Register OTA Update routes to blueprint"""
    
    @gm_blueprint.route('/update')
    def update_page():
        """OTA Update management page"""
        try:
            controller = get_update_controller()
            
            # Get current version info
            version_info = controller.get_current_version()
            
            # Get recent commits
            recent_commits = controller.get_git_log(limit=10)
            
            # Get update status
            update_status = controller.get_update_status()
            
            hostname = socket.gethostname()
            
            return render_template('geomaxima/ota_update.html',
                                 feature_enabled=True,
                                 version_info=version_info,
                                 recent_commits=recent_commits,
                                 update_status=update_status,
                                 hostname=hostname)
            
        except Exception as e:
            logger.error(f"Update page error: {e}", exc_info=True)
            hostname = socket.gethostname()
            return render_template('geomaxima/ota_update.html',
                                 feature_enabled=False,
                                 error=str(e),
                                 version_info={},
                                 recent_commits=[],
                                 update_status={},
                                 hostname=hostname)
    
    # API Routes
    @gm_blueprint.route('/api/update/version', methods=['GET'])
    def api_get_version():
        """Get current version information"""
        try:
            controller = get_update_controller()
            version_info = controller.get_current_version()
            return jsonify({
                'success': True,
                'version': version_info
            })
        except Exception as e:
            logger.error(f"Failed to get version: {e}")
            return jsonify({'success': False, 'error': str(e)}), 500
    
    @gm_blueprint.route('/api/update/check', methods=['POST'])
    def api_check_updates():
        """Check for available updates"""
        try:
            controller = get_update_controller()
            update_info = controller.check_for_updates()
            
            if 'error' in update_info:
                return jsonify({'success': False, 'error': update_info['error']}), 500
            
            return jsonify({
                'success': True,
                'updates': update_info
            })
        except Exception as e:
            logger.error(f"Failed to check updates: {e}")
            return jsonify({'success': False, 'error': str(e)}), 500
    
    @gm_blueprint.route('/api/update/perform', methods=['POST'])
    def api_perform_update():
        """Perform OTA update (async - starts in background thread)"""
        try:
            controller = get_update_controller()
            data = request.get_json() or {}
            restart_service = data.get('restart_service', True)

            # Refresh persisted status (update runs in detached process)
            current_status = controller.get_update_status()
            if current_status.get('update_in_progress'):
                # Idempotent: don't error on double-click / repeat request
                return jsonify({
                    'success': True,
                    'message': 'Update already in progress',
                    'status': 'in_progress',
                    'current_status': current_status
                })
            
            # Start update in background thread
            def perform_update_async():
                try:
                    logger.info("Background update thread started")
                    result = controller.perform_update(restart_service=restart_service)
                    logger.info(f"Update completed: success={result.get('success')}")
                except Exception as e:
                    logger.error(f"Async update failed with exception: {e}", exc_info=True)
                    # Save error to status file
                    controller.last_update_status = {
                        'success': False,
                        'error': str(e),
                        'log': f'Update failed with exception:\n{str(e)}',
                        'completed': True,
                        'timestamp': datetime.now().isoformat()
                    }
                    controller._save_status_to_file()
            
            update_thread = threading.Thread(target=perform_update_async, daemon=True)
            update_thread.start()
            logger.info("Update thread started successfully")
            
            # Return immediately - client will poll /api/update/status
            return jsonify({
                'success': True,
                'message': 'Update started in background',
                'status': 'in_progress'
            })
            
        except Exception as e:
            logger.error(f"Failed to start update: {e}")
            return jsonify({'success': False, 'error': str(e)}), 500
    
    @gm_blueprint.route('/api/update/status', methods=['GET'])
    def api_update_status():
        """Get update operation status"""
        try:
            controller = get_update_controller()
            status = controller.get_update_status()
            return jsonify({
                'success': True,
                'status': status
            })
        except Exception as e:
            logger.error(f"Failed to get update status: {e}")
            return jsonify({'success': False, 'error': str(e)}), 500

    @gm_blueprint.route('/api/update/github-token', methods=['GET'])
    def api_github_token_status():
        """Return whether a GitHub token is configured"""
        try:
            controller = get_update_controller()
            return jsonify({
                'success': True,
                'configured': controller.is_token_configured()
            })
        except Exception as e:
            logger.error(f"Failed to get GitHub token status: {e}")
            return jsonify({'success': False, 'error': str(e)}), 500

    @gm_blueprint.route('/api/update/github-token', methods=['POST'])
    def api_set_github_token():
        """Store or clear GitHub token for private OTA repo access"""
        try:
            controller = get_update_controller()
            data = request.get_json() or {}
            token = data.get('token', '')
            success = controller.set_github_token(token)

            if not success:
                return jsonify({'success': False, 'error': 'Failed to save token'}), 500

            return jsonify({
                'success': True,
                'configured': controller.is_token_configured()
            })
        except Exception as e:
            logger.error(f"Failed to save GitHub token: {e}")
            return jsonify({'success': False, 'error': str(e)}), 500
    
    @gm_blueprint.route('/api/update/log', methods=['GET'])
    def api_git_log():
        """Get git commit history"""
        try:
            controller = get_update_controller()
            limit = request.args.get('limit', 20, type=int)
            commits = controller.get_git_log(limit=min(limit, 100))
            
            return jsonify({
                'success': True,
                'commits': commits
            })
        except Exception as e:
            logger.error(f"Failed to get git log: {e}")
            return jsonify({'success': False, 'error': str(e)}), 500
    
    @gm_blueprint.route('/api/update/rollback', methods=['POST'])
    def api_rollback():
        """Rollback to a previous commit (async)"""
        try:
            controller = get_update_controller()
            data = request.get_json() or {}
            
            commit_hash = data.get('commit_hash')
            if not commit_hash:
                return jsonify({'success': False, 'error': 'commit_hash is required'}), 400
            
            # Refresh persisted status (rollback also runs async)
            current_status = controller.get_update_status()
            if current_status.get('update_in_progress'):
                # Idempotent: don't error if another operation is already running
                return jsonify({
                    'success': True,
                    'message': 'Update/rollback already in progress',
                    'status': 'in_progress',
                    'current_status': current_status
                })
            
            restart_service = data.get('restart_service', True)
            
            # Start rollback in background thread
            def perform_rollback_async():
                try:
                    controller.rollback_to_commit(commit_hash, restart_service=restart_service)
                except Exception as e:
                    logger.error(f"Async rollback failed: {e}")
            
            rollback_thread = threading.Thread(target=perform_rollback_async, daemon=True)
            rollback_thread.start()
            
            # Return immediately - client will poll /api/update/status
            return jsonify({
                'success': True,
                'message': 'Rollback started in background',
                'status': 'in_progress'
            })
            
        except Exception as e:
            logger.error(f"Failed to start rollback: {e}")
            return jsonify({'success': False, 'error': str(e)}), 500
    
    @gm_blueprint.route('/api/update/previous', methods=['GET'])
    def api_previous_commit():
        """Get previous commit for quick rollback"""
        try:
            controller = get_update_controller()
            previous = controller.get_previous_commit()
            
            if previous:
                return jsonify({
                    'success': True,
                    'previous_commit': previous
                })
            else:
                return jsonify({
                    'success': False,
                    'error': 'No previous commit found'
                }), 404
                
        except Exception as e:
            logger.error(f"Failed to get previous commit: {e}")
            return jsonify({'success': False, 'error': str(e)}), 500
    
    logger.info("OTA Update feature routes registered")
