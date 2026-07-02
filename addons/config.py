"""
GeoMaxima Configuration
Separate configuration for custom extensions
"""

import os

# GeoMaxima Version
VERSION = "4.1.0"

# Repository for OTA updates
GEOMAXIMA_REPO = "https://github.com/peshovp/GeoMaxima-BS.git"
GEOMAXIMA_BRANCH = "master"

# Base paths
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
RTKBASE_DIR = os.path.dirname(BASE_DIR)
WEB_APP_DIR = os.path.join(RTKBASE_DIR, "web_app")

# Feature flags
FEATURES = {
    "wireguard_client": True,
    "auto_survey_feature": True,  # Auto Survey-In for precise positioning
    "ota_update_feature": True,   # OTA Update Manager for remote updates
    "watchdog_feature": True,     # System monitoring and auto-recovery
    "gnss_config_feature": True,  # GNSS Receiver Configuration Manager
    "external_integration_feature": True,  # GNSS.NET Caster API Integration
    "system_settings_feature": True,  # Full raspi-config control via web UI
}

# GeoMaxima specific settings
SETTINGS = {
    "enable_logging": True,
    "log_level": "INFO",
    "data_retention_days": 30,
}

# API settings
API_PREFIX = "/geomaxima/api"
API_VERSION = "v1"

# Database settings (if needed for custom features)
USE_CUSTOM_DB = False
CUSTOM_DB_PATH = os.path.join(BASE_DIR, "data", "geomaxima.db")

def get_version():
    """Get GeoMaxima version"""
    try:
        with open(os.path.join(BASE_DIR, "VERSION"), "r") as f:
            return f.read().strip()
    except:
        return VERSION

def is_feature_enabled(feature_name):
    """Check if a feature is enabled"""
    return FEATURES.get(feature_name, False)

def get_setting(key, default=None):
    """Get a GeoMaxima setting"""
    return SETTINGS.get(key, default)
