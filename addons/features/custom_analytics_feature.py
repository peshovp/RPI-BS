"""
Custom Analytics Feature
Real-time GNSS data analytics and visualization
"""

from flask import render_template, jsonify, request
import logging
import sys
import os

# Add web_app to path to import RTKBase modules
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../web_app'))

try:
    from .custom_analytics.analytics_controller import AnalyticsController
except ImportError:
    from custom_analytics.analytics_controller import AnalyticsController

logger = logging.getLogger(__name__)

# Global controller instance
_analytics_controller = None


def get_analytics_controller():
    """Get or create analytics controller instance"""
    global _analytics_controller
    
    if _analytics_controller is None:
        _analytics_controller = AnalyticsController()
        logger.info("AnalyticsController initialized")
    
    return _analytics_controller


def register_routes(app, gm_blueprint):
    """Register Custom Analytics routes"""
    
    # Access to RTKBase RTKLIB instance for real-time data
    try:
        rtkbase_instance = app.config.get('RTKBASE_INSTANCE')
        if rtkbase_instance:
            logger.info("Custom Analytics connected to RTKBase instance")
    except Exception as e:
        logger.warning(f"Could not connect to RTKBase instance: {e}")
        rtkbase_instance = None
    
    @gm_blueprint.route('/analytics')
    def analytics_page():
        """Custom Analytics dashboard page"""
        try:
            import socket
            hostname = socket.gethostname()
            
            return render_template(
                'geomaxima/custom_analytics.html',
                feature_enabled=True,
                hostname=hostname
            )
        except Exception as e:
            logger.error(f"Analytics page error: {e}")
            return render_template(
                'geomaxima/custom_analytics.html',
                feature_enabled=False,
                error=str(e)
            )
    
    @gm_blueprint.route('/api/analytics/satellite-data', methods=['GET'])
    def api_satellite_data():
        """Get satellite tracking data from RTKBase with elevation/azimuth"""
        try:
            controller = get_analytics_controller()
            
            # Try to get real data from RTKBase
            satellites = []
            debug_info = {}
            
            if rtkbase_instance and hasattr(rtkbase_instance, 'rtkc'):
                # Check RTKLIB status
                debug_info['rtkbase_available'] = True
                debug_info['rtkc_launched'] = getattr(rtkbase_instance.rtkc, 'launched', False)
                debug_info['has_child'] = hasattr(rtkbase_instance.rtkc, 'child')
                
                # Get latest observation data with elevation/azimuth
                obs_data = rtkbase_instance.rtkc.obs_rover
                debug_info['obs_data_keys'] = len(obs_data) if obs_data else 0
                
                if obs_data:
                    # Pass RTK controller to get satinfo data
                    satellites = controller.process_satellite_data(obs_data, rtkbase_instance.rtkc)
                    logger.debug(f"Processed {len(satellites)} satellites from RTKBase")
                else:
                    logger.warning("No observation data available from RTKBase")
            else:
                debug_info['rtkbase_available'] = False
            
            # If no real data, use empty list (not mock data)
            if not satellites:
                logger.info(f"No satellite data - Debug: {debug_info}")
            
            return jsonify({
                'success': True,
                'satellites': satellites,
                'timestamp': 'now',
                'source': 'rtkbase' if satellites else 'none',
                'debug': debug_info  # Include debug info
            })
            
        except Exception as e:
            logger.error(f"Failed to get satellite data: {e}", exc_info=True)
            return jsonify({'success': False, 'error': str(e)}), 500
    
    @gm_blueprint.route('/api/analytics/position-stats', methods=['GET'])
    def api_position_stats():
        """Get position quality statistics from RTKBase"""
        try:
            controller = get_analytics_controller()
            
            # Try to get real status data from RTKBase
            stats = {}
            
            if rtkbase_instance and hasattr(rtkbase_instance, 'rtkc'):
                # Get latest status data
                status_data = rtkbase_instance.rtkc.status
                
                if status_data:
                    stats = controller.process_rtk_status(status_data)
                    logger.debug(f"Processed position stats from RTKBase")
                else:
                    logger.warning("No status data available from RTKBase")
            
            # If no real data, return empty stats
            if not stats:
                stats = {
                    'fix_type': 'No Data',
                    'satellites_used': 0,
                    'std_horizontal': 0.0,
                    'std_vertical': 0.0,
                    'age_of_differential': 0.0
                }
            
            return jsonify({
                'success': True,
                'stats': stats,
                'source': 'rtkbase' if stats.get('satellites_used', 0) > 0 else 'none'
            })
            
        except Exception as e:
            logger.error(f"Failed to get position stats: {e}", exc_info=True)
            return jsonify({'success': False, 'error': str(e)}), 500
    
    @gm_blueprint.route('/api/analytics/history', methods=['GET'])
    def api_historical_data():
        """Get historical SNR data for graphing"""
        try:
            controller = get_analytics_controller()
            
            prn = request.args.get('prn')  # Optional: specific satellite
            hours = int(request.args.get('hours', 1))  # Default 1 hour
            
            history = controller.get_historical_snr(prn, hours)
            
            return jsonify({
                'success': True,
                'history': history,
                'hours': hours
            })
            
        except Exception as e:
            logger.error(f"Failed to get historical data: {e}", exc_info=True)
            return jsonify({'success': False, 'error': str(e)}), 500
    
    @gm_blueprint.route('/api/analytics/fix-history', methods=['GET'])
    def api_fix_history():
        """Get historical fix type data"""
        try:
            controller = get_analytics_controller()
            
            hours = int(request.args.get('hours', 1))  # Default 1 hour
            
            history = controller.get_fix_history(hours)
            
            return jsonify({
                'success': True,
                'history': history,
                'hours': hours
            })
            
        except Exception as e:
            logger.error(f"Failed to get fix history: {e}", exc_info=True)
            return jsonify({'success': False, 'error': str(e)}), 500
    
    @gm_blueprint.route('/api/analytics/export', methods=['GET'])
    def api_export_data():
        """Export analytics data as CSV or JSON"""
        try:
            from flask import make_response
            
            controller = get_analytics_controller()
            
            format = request.args.get('format', 'csv')  # csv or json
            hours = int(request.args.get('hours', 24))  # Default 24 hours
            
            data = controller.export_data(format, hours)
            
            if format == 'csv':
                response = make_response(data)
                response.headers['Content-Type'] = 'text/csv'
                response.headers['Content-Disposition'] = f'attachment; filename=analytics_{hours}h.csv'
            else:
                response = make_response(data)
                response.headers['Content-Type'] = 'application/json'
                response.headers['Content-Disposition'] = f'attachment; filename=analytics_{hours}h.json'
            
            return response
            
        except Exception as e:
            logger.error(f"Failed to export data: {e}", exc_info=True)
            return jsonify({'success': False, 'error': str(e)}), 500
    
    @gm_blueprint.route('/api/analytics/alerts', methods=['GET'])
    def api_get_alerts():
        """Get recent alerts"""
        try:
            controller = get_analytics_controller()
            
            limit = int(request.args.get('limit', 10))
            
            alerts = controller.get_alerts(limit)
            
            return jsonify({
                'success': True,
                'alerts': alerts,
                'count': len(alerts)
            })
            
        except Exception as e:
            logger.error(f"Failed to get alerts: {e}", exc_info=True)
            return jsonify({'success': False, 'error': str(e)}), 500
    
    @gm_blueprint.route('/api/analytics/alerts/clear', methods=['POST'])
    def api_clear_alerts():
        """Clear all alerts"""
        try:
            controller = get_analytics_controller()
            controller.clear_alerts()
            
            return jsonify({
                'success': True,
                'message': 'Alerts cleared'
            })
            
        except Exception as e:
            logger.error(f"Failed to clear alerts: {e}", exc_info=True)
            return jsonify({'success': False, 'error': str(e)}), 500
    
    logger.info("Custom Analytics routes registered (5 features enabled)")


