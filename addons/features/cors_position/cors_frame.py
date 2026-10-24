"""Convert CORS positions to BGS2005 (ETRF2000 at epoch 2005.0)."""

import math
from typing import Any, Callable, Dict, Optional

BGS2005_FRAME = "ETRF2000@2005.0"
MAX_FRAME_SHIFT_M = 2.0

try:
    from .cors_rtk_parse import geodetic_to_ecef
except ImportError:
    from cors_rtk_parse import geodetic_to_ecef


class FrameError(Exception):
    """Error in coordinate frame conversion."""
    pass


def _is_finite_number(x: Any) -> bool:
    """Check if x is a finite number (not bool)."""
    if isinstance(x, bool):
        return False
    try:
        return math.isfinite(float(x))
    except (TypeError, ValueError):
        return False


def to_bgs2005(
    lat: float,
    lon: float,
    h: float,
    frame: str,
    epoch: Optional[float],
    *,
    itrf_fn: Optional[Callable] = None,
    epoch_fn: Optional[Callable] = None,
    velocity_fn: Optional[Callable] = None,
) -> Dict[str, Any]:
    """Convert a position to BGS2005 (ETRF2000 at epoch 2005.0).

    Supported frames:
        - "ETRF2000@2005.0" (BGS2005): already in target frame; epoch ignored.
        - "ITRF2020@epoch": ITRF2020 coordinates at the given coordinate epoch;
          epoch is the epoch of the coordinates.
        - "ETRF2000@epoch": ETRF2000 coordinates at the given coordinate epoch;
          epoch is the epoch of the coordinates.
        - "ITRF2020@date": ITRF2020 coordinates at the observation date;
          epoch is the observation epoch (decimal year).
        - "WGS84-approx": not supported (raises FrameError).

    Args:
        lat: Latitude in degrees.
        lon: Longitude in degrees.
        h: Ellipsoidal height in metres.
        frame: Source coordinate frame.
        epoch: For "@epoch" frames, the epoch of the coordinates (float year).
            For "@date" frames, the observation epoch (float year). Ignored for
            BGS2005.
        itrf_fn: Optional injected ITRF2020->BGS2005 conversion function.
        epoch_fn: Optional injected epoch reduction function.
        velocity_fn: Optional injected velocity loader function.

    Returns:
        Dict with converted position and metadata.

    Raises:
        FrameError: On validation or conversion failure.
    """
    # Validate position
    if not (_is_finite_number(lat) and _is_finite_number(lon) and _is_finite_number(h)):
        raise FrameError("invalid position")

    # Validate frame
    if frame not in ("ETRF2000@2005.0", "ITRF2020@epoch", "ETRF2000@epoch", "ITRF2020@date", "WGS84-approx"):
        raise FrameError("unknown coordinate system")

    # Validate epoch for epoch-dependent frames
    if frame in ("ITRF2020@epoch", "ETRF2000@epoch"):
        if not _is_finite_number(epoch):
            raise FrameError("the coordinate epoch of the account is required")
        if not (1990.0 <= float(epoch) <= 2100.0):
            raise FrameError("the coordinate epoch of the account is required")
    elif frame == "ITRF2020@date":
        if not _is_finite_number(epoch):
            raise FrameError("the observation epoch is required")
        if not (1990.0 <= float(epoch) <= 2100.0):
            raise FrameError("the observation epoch is required")

    if frame == "WGS84-approx":
        raise FrameError(
            "WGS84 is not a precisely defined frame; "
            "set the account to ITRF2020 with an epoch or to ETRF2000"
        )

    # Perform conversion
    if frame == "ETRF2000@2005.0":
        out_lat, out_lon, out_h = lat, lon, h
        method = "none"
        provisional = False
        provisional_reason = None
    elif frame in ("ITRF2020@epoch", "ITRF2020@date"):
        try:
            if itrf_fn is not None:
                r = itrf_fn(lat, lon, h, epoch)
            else:
                from ..auto_survey.bgs2005_transformer import (
                    GeodeticPoint,
                    itrf2020_to_bgs2005,
                )
                r = itrf2020_to_bgs2005(
                    GeodeticPoint(lat=lat, lon=lon, height=h), epoch
                )
            out_lat = r["lat_dd"]
            out_lon = r["lon_dd"]
            out_h = r["height_m"]
            method = "itrf2020_to_bgs2005"
            provisional = bool(r.get("coordinate_provisional"))
            provisional_reason = r.get("coordinate_provisional_reason")
        except Exception:
            raise FrameError("the frame conversion failed")
    elif frame == "ETRF2000@epoch":
        try:
            if velocity_fn is not None:
                velocity = velocity_fn()
            else:
                from ..auto_survey.bgs2005_transformer import (
                    _load_station_velocity_neu_mm_per_yr,
                )
                velocity = _load_station_velocity_neu_mm_per_yr()

            if epoch_fn is not None:
                out_lat, out_lon, out_h = epoch_fn(
                    lat, lon, h, epoch, 2005.0, velocity
                )
            else:
                from ..auto_survey.bgs2005_transformer import (
                    _apply_epoch_reduction,
                )
                out_lat, out_lon, out_h = _apply_epoch_reduction(
                    lat, lon, h, epoch, 2005.0, velocity
                )
            method = "etrf2000_epoch_reduction"
            provisional = True
            provisional_reason = "epoch reduction uses the SOFI velocity as a proxy"
        except Exception:
            raise FrameError("the frame conversion failed")
    else:
        raise FrameError("unknown coordinate system")

    # Validate output is finite
    if not (_is_finite_number(out_lat) and _is_finite_number(out_lon) and _is_finite_number(out_h)):
        raise FrameError("the frame conversion failed")

    # Compute shift
    x_in, y_in, z_in = geodetic_to_ecef(lat, lon, h)
    x_out, y_out, z_out = geodetic_to_ecef(out_lat, out_lon, out_h)
    dx = x_out - x_in
    dy = y_out - y_in
    dz = z_out - z_in
    shift_m = math.sqrt(dx * dx + dy * dy + dz * dz)

    if shift_m > MAX_FRAME_SHIFT_M:
        raise FrameError("implausible frame shift")

    # Compute N/E/U components
    dlat = out_lat - lat
    dlon = out_lon - lon
    dh = out_h - h
    shift_n_m = dlat * 111132.92
    shift_e_m = dlon * 111412.84 * math.cos(math.radians(lat))
    shift_u_m = dh

    return {
        "lat": out_lat,
        "lon": out_lon,
        "h": out_h,
        "frame_in": frame,
        "epoch_in": epoch,
        "method": method,
        "shift_m": shift_m,
        "shift_n_m": shift_n_m,
        "shift_e_m": shift_e_m,
        "shift_u_m": shift_u_m,
        "provisional": provisional,
        "provisional_reason": provisional_reason,
    }
