"""
Auto Survey-In Feature for RTKBase
==================================

Automated survey-in with PRIDE-PPPAR ambiguity-resolved PPP.

Features:
- RTKBase auto-integration (discovers paths automatically)
- RINEX conversion from raw GNSS logs (UBX/RTCM) at 30 s intervals
- PRIDE-PPPAR ambiguity-resolved PPP computed once for the whole
  survey window when precise products are published
- ITRF2020 -> ETRF2000/BGS2005 transformation with epoch reduction
- Ellipsoidal broadcast height (geoid correction for display only)
- Survey runs as its own systemd service (survey_runner) with
  reconcile/resume capability
- File service is survey-only
- State persistence for restart recovery

Author: GeoMaxima Team
Version: 2.0.0
"""

__version__ = "2.0.0"

from .survey_controller import SurveyController
from .rtkbase_config import RTKBaseConfig
from .rinex_converter import RINEXConverter
from .geoid_corrector import GeoidCorrector, GeoidModel
from .state_manager import StateManager, SurveyState

__all__ = [
    "SurveyController",
    "RTKBaseConfig",
    "RINEXConverter",
    "GeoidCorrector",
    "GeoidModel",
    "StateManager",
    "SurveyState"
]
