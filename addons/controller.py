"""
GeoMaxima Controller
Main controller for GeoMaxima extension system
"""

from flask import Blueprint, render_template, jsonify, request
import logging
import sys
import os

# Note: sys.path is already configured by server.py
# Do NOT modify sys.path here to avoid import conflicts

try:
    from geomaxima import config
except ImportError:
    # Fallback if geomaxima is not properly installed
    config = None

# Create Blueprint with template and static folders
geomaxima_bp = Blueprint(
    'geomaxima', 
    __name__, 
    url_prefix='/geomaxima',
    template_folder='templates',
    static_folder='static',
    static_url_path='/static/geomaxima'
)

logger = logging.getLogger(__name__)

# Flag to track if routes are registered
_routes_registered = False


class GeoMaximaController:
    """Main controller for GeoMaxima extensions"""
    
    def __init__(self, app=None):
        self.app = app
        self.enabled = False
        self.version = "unknown"
        self.features = {}
        
        if config:
            self.enabled = True
            self.version = config.get_version()
            self.features = config.FEATURES
            logger.info(f"GeoMaxima v{self.version} initialized")
    
    def register_routes(self, app):
        """Register all GeoMaxima routes"""
        global _routes_registered
        
        if not self.enabled:
            logger.warning("GeoMaxima is not enabled")
            return
        
        # Check if blueprint is already registered
        if 'geomaxima' in [bp.name for bp in app.blueprints.values()]:
            logger.info("GeoMaxima blueprint already registered, skipping")
            return
        
        # Register routes BEFORE registering blueprint
        if not _routes_registered:
            self._register_core_routes()
            self._load_feature_modules()
            _routes_registered = True
        
        # Now register blueprint with routes already defined
        app.register_blueprint(geomaxima_bp)
        
        logger.info("GeoMaxima routes registered")
    
    def _register_core_routes(self):
        """Register core GeoMaxima routes"""
        
        @geomaxima_bp.before_app_request
        def reload_rtkbase_config():
            """Force reload of RTKBase settings on every request if changed"""
            try:
                import sys
                import os
                if '__main__' in sys.modules:
                    main = sys.modules['__main__']
                    if hasattr(main, 'rtkbaseconfig'):
                        cfg = main.rtkbaseconfig
                        # Check mtime to avoid unnecessary reloads
                        try:
                            settings_path = cfg.user_settings_path
                            mtime = os.path.getmtime(settings_path)
                            # Store last_mtime on the config object itself
                            if not hasattr(cfg, '_last_mtime') or mtime > cfg._last_mtime:
                                cfg.reload_settings()
                                cfg._last_mtime = mtime
                        except Exception:
                            pass
            except Exception:
                pass
        
        @geomaxima_bp.route('/')
        def index():
            """GeoMaxima main page"""
            return render_template(
                'geomaxima/dashboard.html',
                version=self.version,
                features=self.features
            )
        
        @geomaxima_bp.route('/rtcm-info')
        def rtcm_info():
            """RTCM message presets information page"""
            import socket
            hostname = socket.gethostname()
            return render_template(
                'geomaxima/rtcm_info.html',
                hostname=hostname
            )
        
        @geomaxima_bp.route('/api/info')
        def api_info():
            """Get GeoMaxima info"""
            return jsonify({
                "name": "GeoMaxima",
                "version": self.version,
                "enabled": self.enabled,
                "features": self.features,
                "repository": config.GEOMAXIMA_REPO if config else "unknown"
            })
        
        @geomaxima_bp.route('/api/status')
        def api_status():
            """Get GeoMaxima status"""
            return jsonify({
                "status": "running" if self.enabled else "disabled",
                "version": self.version,
                "features_count": len([f for f, enabled in self.features.items() if enabled])
            })
        
        @geomaxima_bp.route('/api/features')
        def api_features():
            """List all features"""
            return jsonify({
                "features": [
                    {
                        "name": name,
                        "enabled": enabled,
                        "description": f"Feature: {name}"
                    }
                    for name, enabled in self.features.items()
                ]
            })
    
    def _load_feature_modules(self):
        """Load feature modules dynamically"""
        features_dir = os.path.join(config.BASE_DIR, 'features')
        
        logger.info(f"Loading features from: {features_dir}")
        logger.info(f"self.app = {self.app}")
        
        if not os.path.exists(features_dir):
            logger.warning(f"Features directory not found: {features_dir}")
            return
        
        # Dynamically load feature modules
        available_files = os.listdir(features_dir)
        logger.info(f"Available feature files: {available_files}")
        
        for filename in available_files:
            if filename.endswith('.py') and not filename.startswith('__'):
                feature_name = filename[:-3]
                is_enabled = config.is_feature_enabled(feature_name)
                logger.info(f"Checking feature: {feature_name}, enabled: {is_enabled}")
                
                if is_enabled:
                    try:
                        module_name = f"geomaxima.features.{feature_name}"
                        logger.info(f"Loading module: {module_name}")
                        feature_module = __import__(module_name, fromlist=['register_routes'])
                        
                        if hasattr(feature_module, 'register_routes'):
                            logger.info(f"Calling register_routes for {feature_name}")
                            feature_module.register_routes(self.app, geomaxima_bp)
                            logger.info(f"✓ Loaded feature: {feature_name}")
                        else:
                            logger.warning(f"Feature {feature_name} has no register_routes function")
                    except Exception as e:
                        logger.error(f"Failed to load feature {feature_name}: {e}", exc_info=True)
        
        # Register RTCM dropdown injector
        try:
            from geomaxima.features.rtcm_dropdown_injector import register_rtcm_injector
            register_rtcm_injector(self.app)
            logger.info("✓ RTCM dropdown injector registered")
        except Exception as e:
            logger.warning(f"Failed to register RTCM injector: {e}")
        
        # Register RTKBase settings proxy
        try:
            from geomaxima.features.rtkbase_proxy import register_rtkbase_proxy
            register_rtkbase_proxy(self.app)
            logger.info("✓ RTKBase settings proxy registered")
        except Exception as e:
            logger.warning(f"Failed to register RTKBase proxy: {e}")
    
    def check_update_available(self):
        """Check if update is available"""
        # This will be implemented in geomaxima_update.sh
        return {
            "update_available": False,
            "current_version": self.version,
            "latest_version": self.version
        }


# Global instance
_controller = None

def get_controller():
    """Get GeoMaxima controller instance"""
    global _controller
    if _controller is None:
        _controller = GeoMaximaController()
    return _controller

def init_geomaxima(app):
    """Initialize GeoMaxima with Flask app"""
    controller = get_controller()
    controller.app = app
    controller.register_routes(app)
    return controller
