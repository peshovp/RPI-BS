"""Apply a confirmed CORS position to the RTKBase configuration.

This module provides the guarded function that writes a position into
settings.conf and restarts the streaming services. It is called after a
human has confirmed the CORS proposal in the UI.
"""

import logging
import math
from typing import Any, Callable, Dict, Optional, Tuple

from ..auto_survey.rtkbase_config import RTKBaseConfig

try:
    from audit_logger import log_event
except ImportError:
    try:
        from web_app.audit_logger import log_event
    except ImportError:
        log_event = lambda *a, **k: None

logger = logging.getLogger(__name__)

# Expected position range for Bulgaria (approximate)
AREA = {"lat": (41.0, 44.5), "lon": (22.0, 29.0), "h": (-50.0, 3000.0)}

# Maximum allowed change without force (metres)
MAX_HORIZONTAL_CHANGE_M = 1.0
MAX_VERTICAL_CHANGE_M = 2.0


def position_change_m(
    previous: Tuple[float, float, float],
    new: Tuple[float, float, float],
) -> Tuple[float, float]:
    """Compute the horizontal and vertical change between two positions.

    Args:
        previous: (lat, lon, h) in degrees, degrees, metres.
        new: (lat, lon, h) in degrees, degrees, metres.

    Returns:
        (horizontal_m, vertical_m)
    """
    dlat = new[0] - previous[0]
    dlon = new[1] - previous[1]
    dh = new[2] - previous[2]

    # Approximate metres per degree at the new latitude
    m_per_deg_lat = 111132.92
    m_per_deg_lon = 111412.84 * math.cos(math.radians(new[0]))

    horizontal = math.sqrt(
        (dlat * m_per_deg_lat) ** 2 + (dlon * m_per_deg_lon) ** 2
    )
    vertical = abs(dh)

    return (horizontal, vertical)


def _clean_meta(meta: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    """Sanitise metadata for audit logging.

    Keeps only entries with string keys and values that are str (max 100
    chars), int, float, bool, or None.
    """
    if meta is None:
        return {}

    cleaned = {}
    for key, value in meta.items():
        if not isinstance(key, str):
            continue
        if isinstance(value, str):
            cleaned[key] = value[:100]
        elif isinstance(value, (int, float, bool)) or value is None:
            cleaned[key] = value
    return cleaned


def apply_position(
    rtkbase: RTKBaseConfig,
    lat: float,
    lon: float,
    h: float,
    *,
    source: str,
    meta: Optional[Dict[str, Any]] = None,
    restart: Optional[Callable[[], None]] = None,
    announce: Optional[Callable[[], None]] = None,
    force: bool = False,
    audit: Optional[Callable[..., None]] = None,
) -> Dict[str, Any]:
    """Apply a confirmed position to the RTKBase configuration.

    Args:
        rtkbase: RTKBaseConfig instance.
        lat: Latitude in degrees.
        lon: Longitude in degrees.
        h: Ellipsoidal height in metres.
        source: Short source identifier (e.g. "cors").
        meta: Optional metadata for audit logging.
        restart: Optional callable to restart streaming services.
        announce: Optional callable called just before restart.
        force: If True, allow changes larger than the default thresholds.
        audit: Optional audit logging callable (defaults to imported log_event).

    Returns:
        Dict with keys: ok, reason, previous, applied, change_h_m,
        change_v_m, restart_ok.
    """
    if audit is None:
        audit = log_event

    result = {
        "ok": False,
        "reason": None,
        "previous": None,
        "applied": None,
        "change_h_m": None,
        "change_v_m": None,
        "restart_ok": None,
    }

    try:
        # Step 1: Validate position
        for name, value in [("lat", lat), ("lon", lon), ("h", h)]:
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                result["reason"] = "invalid position"
                audit("cors", "position_apply_refused", {
                    "source": source,
                    "reason": result["reason"],
                    "position": [lat, lon, h],
                })
                return result
            if not math.isfinite(value):
                result["reason"] = "invalid position"
                audit("cors", "position_apply_refused", {
                    "source": source,
                    "reason": result["reason"],
                    "position": [lat, lon, h],
                })
                return result

        if not (AREA["lat"][0] <= lat <= AREA["lat"][1]):
            result["reason"] = "position outside the expected area"
            audit("cors", "position_apply_refused", {
                "source": source,
                "reason": result["reason"],
                "position": [lat, lon, h],
            })
            return result
        if not (AREA["lon"][0] <= lon <= AREA["lon"][1]):
            result["reason"] = "position outside the expected area"
            audit("cors", "position_apply_refused", {
                "source": source,
                "reason": result["reason"],
                "position": [lat, lon, h],
            })
            return result
        if not (AREA["h"][0] <= h <= AREA["h"][1]):
            result["reason"] = "position outside the expected area"
            audit("cors", "position_apply_refused", {
                "source": source,
                "reason": result["reason"],
                "position": [lat, lon, h],
            })
            return result

        # Step 2: Read previous position and check change
        previous = RTKBaseConfig(str(rtkbase.settings_file)).get_position()
        if previous is not None:
            result["previous"] = list(previous)
            change_h, change_v = position_change_m(previous, (lat, lon, h))
            result["change_h_m"] = change_h
            result["change_v_m"] = change_v

            if (change_h > MAX_HORIZONTAL_CHANGE_M or
                    change_v > MAX_VERTICAL_CHANGE_M) and not force:
                result["reason"] = "change too large"
                audit("cors", "position_apply_refused", {
                    "source": source,
                    "reason": result["reason"],
                    "previous": list(previous),
                    "proposed": [lat, lon, h],
                    "change_h_m": change_h,
                    "change_v_m": change_v,
                })
                return result

        # Step 3: Update position
        ok = rtkbase.update_position(lat, lon, h)
        if not ok:
            result["reason"] = "settings.conf could not be updated"
            audit("cors", "position_apply_failed", {
                "source": source,
                "reason": result["reason"],
                "position": [lat, lon, h],
            })
            return result

        # Step 4: Verify written position
        verified = RTKBaseConfig(str(rtkbase.settings_file)).get_position()
        if verified is None:
            result["reason"] = "written position did not verify"
            if previous is not None:
                rtkbase.update_position(*previous)
            audit("cors", "position_apply_failed", {
                "source": source,
                "reason": result["reason"],
                "position": [lat, lon, h],
            })
            return result

        # Compare against rounded values (file stores 8 decimals lat/lon, 3 for h)
        if (abs(verified[0] - round(lat, 8)) > 1e-7 or
                abs(verified[1] - round(lon, 8)) > 1e-7 or
                abs(verified[2] - round(h, 3)) > 0.002):
            result["reason"] = "written position did not verify"
            if previous is not None:
                rtkbase.update_position(*previous)
            audit("cors", "position_apply_failed", {
                "source": source,
                "reason": result["reason"],
                "position": [lat, lon, h],
                "verified": list(verified),
            })
            return result

        result["applied"] = [lat, lon, h]

        # Step 5: Announce and restart
        if announce is not None:
            try:
                announce()
            except Exception:
                pass

        if restart is not None:
            try:
                rv = restart()
                if isinstance(rv, dict):
                    result["restart_ok"] = bool(rv.get("success", True)) and not rv.get("failed")
                else:
                    result["restart_ok"] = True
            except Exception:
                result["restart_ok"] = False
                logger.error("Failed to restart streaming services")

        # Step 6: Audit success
        audit("cors", "position_applied", {
            "source": source,
            "previous": result["previous"],
            "applied": result["applied"],
            "change_h_m": result["change_h_m"],
            "change_v_m": result["change_v_m"],
            "forced": bool(force),
            "restart_ok": result["restart_ok"],
            "meta": _clean_meta(meta),
        })

        result["ok"] = True
        return result

    except Exception:
        logger.exception("Internal error in apply_position")
        result["reason"] = "internal error"
        audit("cors", "position_apply_failed", {
            "source": source,
            "reason": "internal error",
            "position": [lat, lon, h],
        })
        return result
