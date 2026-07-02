"""
GeoMaxima Update Feature
Provides web UI for updating GeoMaxima components
"""

import logging
import subprocess
from flask import Blueprint, jsonify
from pathlib import Path

logger = logging.getLogger(__name__)

# Create blueprint
geomaxima_update_bp = Blueprint(
    'geomaxima_update',
    __name__,
    url_prefix='/geomaxima-update'
)

UPDATE_SCRIPT = '/home/peshovp/rtkbase/tools/update_geomaxima.sh'


def register_routes(app, gm_blueprint):
    """Register GeoMaxima update routes"""
    gm_blueprint.register_blueprint(geomaxima_update_bp)
    logger.info("✓ GeoMaxima Update routes registered")


@geomaxima_update_bp.route('/api/check', methods=['GET'])
def check_for_updates():
    """Check if GeoMaxima updates are available"""
    try:
        # Check current version from git
        result = subprocess.run(
            ['git', '-C', '/home/peshovp/rtkbase/geomaxima', 'rev-parse', 'HEAD'],
            capture_output=True,
            text=True,
            timeout=10
        )
        current_commit = result.stdout.strip()
        
        # Check remote version
        subprocess.run(
            ['git', '-C', '/home/peshovp/rtkbase/geomaxima', 'fetch'],
            timeout=30
        )
        
        result = subprocess.run(
            ['git', '-C', '/home/peshovp/rtkbase/geomaxima', 'rev-parse', 'origin/master'],
            capture_output=True,
            text=True,
            timeout=10
        )
        remote_commit = result.stdout.strip()
        
        updates_available = current_commit != remote_commit
        
        return jsonify({
            'success': True,
            'updates_available': updates_available,
            'current_commit': current_commit[:8],
            'remote_commit': remote_commit[:8]
        })
        
    except Exception as e:
        logger.error(f"Check for updates failed: {e}")
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@geomaxima_update_bp.route('/api/update', methods=['POST'])
def update_geomaxima():
    """Execute GeoMaxima update script"""
    try:
        if not Path(UPDATE_SCRIPT).exists():
            return jsonify({
                'success': False,
                'message': f'Update script not found: {UPDATE_SCRIPT}'
            }), 404
        
        logger.info("Starting GeoMaxima update...")
        
        # Run update script
        result = subprocess.run(
            ['bash', UPDATE_SCRIPT],
            capture_output=True,
            text=True,
            timeout=300
        )
        
        if result.returncode == 0:
            logger.info("GeoMaxima update completed successfully")
            return jsonify({
                'success': True,
                'message': 'GeoMaxima updated successfully',
                'output': result.stdout
            })
        else:
            logger.error(f"Update failed: {result.stderr}")
            return jsonify({
                'success': False,
                'message': 'Update failed',
                'error': result.stderr
            }), 500
            
    except subprocess.TimeoutExpired:
        logger.error("Update timeout")
        return jsonify({
            'success': False,
            'message': 'Update timeout (>5 minutes)'
        }), 500
        
    except Exception as e:
        logger.error(f"Update failed: {e}")
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500
