"""
GeoMaxima Package Init
"""

__version__ = "4.1.0"
__author__ = "Your Name"
__description__ = "GeoMaxima Extension for RTKBase"

# The legacy init_geomaxima path (addons/controller.py + addons/config.py)
# is no longer wired into web_app/server.py, which imports addons.features.*
# directly. This package no longer eager-imports them; they are scheduled
# for removal (see docs/PROJECT_AUDIT.md).

__all__ = []
