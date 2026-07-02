"""
Auto Survey-In Feature for RTKBase
==================================

Automated 24-hour survey with hourly coordinate updates.

Features:
- RTKBase auto-integration (discovers paths automatically)
- RINEX conversion from raw GNSS logs (UBX/RTCM)
- SPP positioning with RTKLIB rnx2rtkp
- Weighted averaging with outlier rejection
- Geoid height correction from EGM96/EGM2008
- Hourly coordinate updates to minimize service interruption
- State persistence for restart recovery
- Quality monitoring (stddev, satellites, epochs)

Author: GeoMaxima Team
Version: 1.2.1
"""

__version__ = "1.3.1"

from .survey_controller import SurveyController
from .rtkbase_config import RTKBaseConfig
from .rinex_converter import RINEXConverter
from .spp_processor import SPPProcessor
from .position_estimator import PositionEstimator, PositionEstimate
from .geoid_corrector import GeoidCorrector, GeoidModel
from .config_manager import ConfigManager
from .state_manager import StateManager, SurveyState

__all__ = [
    "SurveyController",
    "RTKBaseConfig",
    "RINEXConverter",
    "SPPProcessor",
    "PositionEstimator",
    "PositionEstimate",
    "GeoidCorrector",
    "GeoidModel",
    "ConfigManager",
    "StateManager",
    "SurveyState"
]
