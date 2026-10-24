"""Pure helper functions for CORS RTK processing.

NMEA GGA parsing, RINEX header position extraction, ECEF/geodetic
conversion, RTKLIB config generation, .pos file parsing and solution
statistics. Python 3, standard library only.
"""

import math
import statistics
from datetime import datetime
from typing import Optional, Tuple, List, Dict, Any


# GRS80/WGS84 ellipsoid constants
_A = 6378137.0
_F = 1.0 / 298.257222101
_E2 = 2.0 * _F - _F * _F

# Spherical approximations for meter conversions
_M_PER_DEG_NORTH = 111132.92
_M_PER_DEG_EAST = 111412.84


def parse_gga(line: str) -> Optional[Dict[str, Any]]:
    """Parse an NMEA GGA sentence.

    Returns a dict with lat, lon, alt_msl, geoid_sep, quality, sats, hdop,
    or None if the line is not a valid GGA sentence.
    """
    line = line.strip()
    if not line.startswith("$"):
        return None

    # Checksum validation
    if "*" in line:
        body, checksum_str = line.split("*", 1)
        try:
            expected = int(checksum_str.strip(), 16)
        except ValueError:
            return None
        actual = 0
        for ch in body[1:]:  # Skip the '$'
            actual ^= ord(ch)
        if actual != expected:
            return None
    else:
        body = line

    parts = body.split(",")
    if len(parts) < 12:
        return None

    # Verify it's a GGA sentence: exactly 6 chars, starts with '$', ends with 'GGA'
    if len(parts[0]) != 6 or parts[0][0] != '$' or parts[0][3:6] != 'GGA':
        return None

    # Parse fields
    try:
        quality = int(parts[6])
    except (ValueError, IndexError):
        return None

    # Latitude
    if not parts[2]:
        return None
    try:
        lat_val = float(parts[2])
        lat_deg = lat_val // 100.0 + (lat_val % 100.0) / 60.0
        if parts[3] == "S":
            lat_deg = -lat_deg
    except (ValueError, IndexError):
        return None

    # Longitude
    if not parts[4]:
        return None
    try:
        lon_val = float(parts[4])
        lon_deg = lon_val // 100.0 + (lon_val % 100.0) / 60.0
        if parts[5] == "W":
            lon_deg = -lon_deg
    except (ValueError, IndexError):
        return None

    # Optional fields
    try:
        alt_msl = float(parts[9]) if parts[9] else None
    except ValueError:
        alt_msl = None

    try:
        geoid_sep = float(parts[11]) if parts[11] else None
    except (ValueError, IndexError):
        geoid_sep = None

    try:
        sats = int(parts[7]) if parts[7] else None
    except (ValueError, IndexError):
        sats = None

    try:
        hdop = float(parts[8]) if parts[8] else None
    except (ValueError, IndexError):
        hdop = None

    return {
        "lat": lat_deg,
        "lon": lon_deg,
        "alt_msl": alt_msl,
        "geoid_sep": geoid_sep,
        "quality": quality,
        "sats": sats,
        "hdop": hdop,
    }


def read_rinex_approx_xyz(path: str) -> Optional[Tuple[float, float, float]]:
    """Read approximate position from RINEX observation file header.

    Returns (x, y, z) in metres or None if not found or invalid.
    """
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f):
                if i >= 200:
                    break
                if "END OF HEADER" in line:
                    break
                # Label is in columns 61-80 (after first 60 chars)
                if len(line) >= 61:
                    label = line[60:80].strip()
                    if label.startswith("APPROX POSITION XYZ"):
                        # Values are in first 60 chars
                        try:
                            values = line[:60].split()
                            if len(values) >= 3:
                                x = float(values[0])
                                y = float(values[1])
                                z = float(values[2])
                                if x == 0.0 and y == 0.0 and z == 0.0:
                                    return None
                                return (x, y, z)
                        except ValueError:
                            return None
    except FileNotFoundError:
        raise
    return None


def geodetic_to_ecef(lat_deg: float, lon_deg: float, h: float) -> Tuple[float, float, float]:
    """Convert geodetic coordinates to ECEF.

    Args:
        lat_deg: Latitude in degrees
        lon_deg: Longitude in degrees
        h: Height above ellipsoid in metres

    Returns:
        (x, y, z) in metres
    """
    lat = math.radians(lat_deg)
    lon = math.radians(lon_deg)

    sin_lat = math.sin(lat)
    cos_lat = math.cos(lat)
    sin_lon = math.sin(lon)
    cos_lon = math.cos(lon)

    N = _A / math.sqrt(1.0 - _E2 * sin_lat * sin_lat)

    x = (N + h) * cos_lat * cos_lon
    y = (N + h) * cos_lat * sin_lon
    z = (N * (1.0 - _E2) + h) * sin_lat

    return (x, y, z)


def ecef_to_geodetic(x: float, y: float, z: float) -> Tuple[float, float, float]:
    """Convert ECEF coordinates to geodetic.

    Uses iterative method accurate to 1e-4 m.

    Args:
        x, y, z: ECEF coordinates in metres

    Returns:
        (lat_deg, lon_deg, h) where h is height above ellipsoid in metres
    """
    # Handle poles
    if abs(x) < 1e-10 and abs(y) < 1e-10:
        lat = math.pi / 2.0 if z > 0 else -math.pi / 2.0
        lon = 0.0
        h = abs(z) - _A * (1.0 - _E2)
        return (math.degrees(lat), math.degrees(lon), h)

    # Initial latitude estimate from spherical approximation
    p = math.sqrt(x * x + y * y)
    lon = math.atan2(y, x)
    lat = math.atan2(z, p * (1.0 - _E2))

    # Iterate to convergence
    for _ in range(20):
        sin_lat = math.sin(lat)
        cos_lat = math.cos(lat)
        N = _A / math.sqrt(1.0 - _E2 * sin_lat * sin_lat)
        h = p / cos_lat - N
        lat_new = math.atan2(z, p * (1.0 - _E2 * N / (N + h)))
        if abs(lat_new - lat) < 1e-12:
            lat = lat_new
            break
        lat = lat_new

    return (math.degrees(lat), math.degrees(lon), h)


def build_rnx2rtkp_conf(
    frequencies: str = "l1+l2",
    navsys: int = 13,
    elmask: float = 15.0,
) -> str:
    """Build RTKLIB rnx2rtkp configuration file content.

    Args:
        frequencies: One of "l1", "l1+l2", "l1+l2+l5"
        navsys: Navigation system bitmask (1-63)
        elmask: Elevation mask in degrees

    Returns:
        Configuration file content as string

    Raises:
        ValueError: If frequencies or navsys are invalid
    """
    if frequencies not in ("l1", "l1+l2", "l1+l2+l5"):
        raise ValueError(f"Invalid frequencies: {frequencies}")
    if not isinstance(navsys, int) or navsys < 1 or navsys > 63:
        raise ValueError(f"Invalid navsys: {navsys}")

    lines = [
        "pos1-posmode       =static",
        f"pos1-frequency     ={frequencies}",
        "pos1-soltype       =forward",
        f"pos1-elmask        ={elmask}",
        f"pos1-navsys        ={navsys}",
        "pos1-exclsats      =",
        "pos2-armode        =fix-and-hold",
        "pos2-gloarmode     =fix-and-hold",
        "pos2-arthres       =3",
        "pos2-arfilter      =on",
        "pos2-minfixsats    =4",
        "pos2-minholdsats   =5",
        "ant1-postype       =llh",
        "ant1-pos1          =0",
        "ant1-pos2          =0",
        "ant1-pos3          =0",
        "ant2-postype       =rinexhead",
        "out-solformat      =llh",
        "out-outhead        =on",
        "out-outopt         =off",
        "out-timesys        =gpst",
        "out-timeform       =hms",
        "out-timendec       =3",
        "out-degform        =deg",
        "out-fieldsep       =",
        "out-height         =ellipsoidal",
        "out-geoid          =internal",
        "out-solstatic      =all",
        "out-nmeaintv1      =0",
        "out-nmeaintv2      =0",
        "out-outstat        =off",
        "stats-eratio1      =100",
        "stats-eratio2      =100",
        "stats-errphase     =0.003",
        "stats-errphaseel   =0.003",
        "stats-errphasebl   =0",
        "stats-errdoppler   =1",
        "stats-prnaccelh    =1",
        "stats-prnaccelv    =1",
        "stats-prnbias      =0.0001",
        "stats-prniono      =0.001",
        "stats-prntrop      =0.0001",
        "stats-prnpos       =0",
        "stats-clkstab      =5e-12",
    ]
    return "\n".join(lines) + "\n"


def parse_pos_file(path: str) -> List[Dict[str, Any]]:
    """Parse an rnx2rtkp .pos file in llh format.

    Returns a list of epoch dicts with time, lat, lon, h, q, ns, sdn, sde, sdu.
    Skips unparseable lines silently.
    """
    epochs = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("%"):
                continue
            parts = line.split()
            if len(parts) < 10:
                continue
            try:
                date_str = parts[0]
                time_str = parts[1]
                dt = datetime.strptime(f"{date_str} {time_str}", "%Y/%m/%d %H:%M:%S.%f")
                lat = float(parts[2])
                lon = float(parts[3])
                h = float(parts[4])
                q = int(parts[5])
                ns = int(parts[6])
                sdn = float(parts[7])
                sde = float(parts[8])
                sdu = float(parts[9])
                epochs.append({
                    "time": dt,
                    "lat": lat,
                    "lon": lon,
                    "h": h,
                    "q": q,
                    "ns": ns,
                    "sdn": sdn,
                    "sde": sde,
                    "sdu": sdu,
                })
            except (ValueError, IndexError):
                continue
    return epochs


def summarize_solution(
    epochs: List[Dict[str, Any]],
    skip_seconds: float = 60.0,
) -> Dict[str, Any]:
    """Summarize RTK solution statistics.

    Args:
        epochs: List of epoch dicts from parse_pos_file
        skip_seconds: Skip initial epochs for convergence

    Returns:
        Dict with solution statistics
    """
    total = len(epochs)
    if total == 0:
        return {
            "total": 0,
            "fixed": 0,
            "fix_ratio": 0.0,
            "first_fix_s": None,
            "used": 0,
            "lat": None,
            "lon": None,
            "h": None,
            "std_n_m": None,
            "std_e_m": None,
            "std_u_m": None,
        }

    fixed = sum(1 for e in epochs if e["q"] == 1)
    fix_ratio = fixed / total if total > 0 else 0.0

    # Find first fix
    first_fix_s = None
    first_time = epochs[0]["time"]
    for e in epochs:
        if e["q"] == 1:
            first_fix_s = (e["time"] - first_time).total_seconds()
            break

    # Filter used epochs (fixed, after skip period)
    used_epochs = [
        e for e in epochs
        if e["q"] == 1 and (e["time"] - first_time).total_seconds() >= skip_seconds
    ]
    used = len(used_epochs)

    if used == 0:
        return {
            "total": total,
            "fixed": fixed,
            "fix_ratio": fix_ratio,
            "first_fix_s": first_fix_s,
            "used": 0,
            "lat": None,
            "lon": None,
            "h": None,
            "std_n_m": None,
            "std_e_m": None,
            "std_u_m": None,
        }

    # Calculate medians
    lats = [e["lat"] for e in used_epochs]
    lons = [e["lon"] for e in used_epochs]
    hs = [e["h"] for e in used_epochs]

    lat_med = statistics.median(lats)
    lon_med = statistics.median(lons)
    h_med = statistics.median(hs)

    # Calculate standard deviations in metres
    if used < 2:
        std_n_m = None
        std_e_m = None
        std_u_m = None
    else:
        # Convert to metres using spherical approximations
        cos_lat = math.cos(math.radians(lat_med))
        norths = [(e["lat"] - lat_med) * _M_PER_DEG_NORTH for e in used_epochs]
        easts = [(e["lon"] - lon_med) * _M_PER_DEG_EAST * cos_lat for e in used_epochs]
        ups = [e["h"] - h_med for e in used_epochs]

        std_n_m = statistics.stdev(norths)
        std_e_m = statistics.stdev(easts)
        std_u_m = statistics.stdev(ups)

    return {
        "total": total,
        "fixed": fixed,
        "fix_ratio": fix_ratio,
        "first_fix_s": first_fix_s,
        "used": used,
        "lat": lat_med,
        "lon": lon_med,
        "h": h_med,
        "std_n_m": std_n_m,
        "std_e_m": std_e_m,
        "std_u_m": std_u_m,
    }


def evaluate_solution(
    summary: Dict[str, Any],
    min_used: int = 60,
    min_fix_ratio: float = 0.5,
    max_std_m: float = 0.05,
) -> Tuple[bool, Optional[str]]:
    """Evaluate RTK solution quality.

    Args:
        summary: Dict from summarize_solution
        min_used: Minimum number of used epochs
        min_fix_ratio: Minimum fix ratio
        max_std_m: Maximum standard deviation in metres

    Returns:
        (passed, reason) where reason is None if passed
    """
    if summary["fixed"] == 0:
        return (False, "no fixed solution")
    if summary["used"] < min_used:
        return (False, "too few fixed epochs")
    if summary["fix_ratio"] < min_fix_ratio:
        return (False, "fix ratio too low")
    if (
        summary["std_n_m"] is None
        or summary["std_e_m"] is None
        or summary["std_u_m"] is None
        or summary["std_n_m"] > max_std_m
        or summary["std_e_m"] > max_std_m
        or summary["std_u_m"] > max_std_m
    ):
        return (False, "solution not stable")
    return (True, None)
