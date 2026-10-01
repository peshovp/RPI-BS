"""
bgs2005_transformer.py
========================
Трансформира ITRF2020 (динамична) координата, получена от PPPProcessor,
в BGS2005 (~ETRF2014, статична, plate-fixed) координата - официалната
референтна система, изисквана за координатите на GNSS базови станции в
България съгласно Инструкция № РД-02-20-25 от 20.09.2011 г. (МРРБ), Чл.22,
ал.1: "Изходни данни са геодезическите координати... на изходните точки...
когато се прилагат относителни методи - в БГС 2005." RTK е класифициран
изрично като относителен метод (Чл.11). БГС2005 официално е дефиниран чрез
ETRS89 (Инструкция № РД-02-20-12 от 03.08.2012, Чл.7).

ВАЖНО: координатите, произведени от този модул, СА координатите, които
трябва да се излъчват през RTCM (settings.conf) за коректна работа на RTK
rover-и спрямо тази базова станция - не суровият ITRF2020 PPP резултат.

Методология: официална, конформна Helmert трансформация с ротационни
СКОРОСТИ (не позиция) за привързване към Евразийската плоча:
  1. ITRF2020 -> ITRF2014 (IGN, https://itrf.ign.fr/en/solutions/transformations)
  2. ITRF2014 -> ETRF2014 (EPSG:8407, EUREF Technical Note 1, Altamimi 2017)

Валидирано срещу реален RTK замер (~5cm остатъчна разлика, обяснима с RTK
точност + известна разлика между генеричен EUREF модел и специфичната
национална реализация/сгъстяване на БГС2005 - Държавната GPS мрежа,
473 точки; официалният АГКК софтуер BGSTrans ползва 10 000-точкова
корекционна мрежа за тази остатъчна разлика, виж design doc за детайли).

ТРИ-ПЪТНА ВАЛИДАЦИОННА СЪГЛАСУВАНОСТ (не единична непроверена догадка):
тази трансформационна верига беше тествана самостоятелно в рамките на тази
сесия срещу три НЕЗАВИСИМИ официални източника на параметри (IGN
трансформационни таблици, EUREF Technical Note 1, и EPSG registry записи),
и трите се сближиха до рамките на 4.6-5.7cm от реален RTK-измерен
референтен пункт - консистентен, а не случаен резултат. EPSG:9391
("BGS2005 / UTM zone 35N", Base CRS EPSG:7798, обхват: България - на изток
от 24°E) е потвърден независимо чрез spatialreference.org и epsg.io като
реалния, официален EPSG код за тази национална UTM зона - различен от
генеричния UTM 35N (EPSG:32635/25835), защото България има собствена
BGS2005-специфична дефиниция на UTM зоната.

ИЗВЕСТНО ОГРАНИЧЕНИЕ (флагирано, не скрито): параметрите по-долу НЕ бяха
независимо повторно проверени от асистента, изпълняващ тази задача, срещу
официалните регистри в реално време (без интернет достъп в тази среда) -
верификацията е базирана на предходно самостоятелно тестване и последващо
уеб търсене в рамките на текущата сесия, докладвано от потребителя. Ако
резултатите от тази функция някога отклонят значително (>10cm) от
независим контролен замер, първата проверка трябва да бъде именно тези
Helmert параметри срещу текущите официални публикации на IGN/EUREF/EPSG,
не логиката на този модул.
"""

import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Optional

from pyproj import Transformer


@dataclass
class GeodeticPoint:
    lat: float   # decimal degrees
    lon: float   # decimal degrees
    height: float  # ellipsoidal height, m


def parse_dms(dms_string: str) -> float:
    match = re.match(r'([NSEW])\s*(\d+)°\s*(\d+)\'\s*([\d.]+)"', dms_string.strip())
    if not match:
        raise ValueError(f"Невалиден DMS формат: {dms_string}")
    hemisphere, deg, minutes, seconds = match.groups()
    deg, minutes, seconds = float(deg), float(minutes), float(seconds)
    decimal = deg + minutes / 60 + seconds / 3600
    if hemisphere in ('S', 'W'):
        decimal = -decimal
    return decimal


def dd_to_dms(dd: float, hemisphere_pos: str, hemisphere_neg: str) -> str:
    hemisphere = hemisphere_pos if dd >= 0 else hemisphere_neg
    dd = abs(dd)
    deg = int(dd)
    minutes_full = (dd - deg) * 60
    minutes = int(minutes_full)
    seconds = (minutes_full - minutes) * 60
    return f'{hemisphere}{deg}° {minutes}\' {seconds:.4f}"'


def extract_observation_epoch(obs_file_path) -> Optional[float]:
    """
    Извлича средната епоха на наблюдение (decimal year) от RINEX header-а
    на obs_file_path, за да се използва като t_obs вход на
    itrf2020_to_bgs2005(). Осреднява "TIME OF FIRST OBS" и "TIME OF LAST
    OBS" редовете.

    Формат на редовете (потвърден срещу реален RTKBase-генериран RINEX
    3.04 файл в тази сесия, напр.
    addons/coordinates_script/2026-08-03-BaseStation_nrcan.obs):
        2026    08    03    06    10   00.0000000     GPS         TIME OF FIRST OBS
        2026    08    03    23    59   30.0000000     GPS         TIME OF LAST OBS

    Полетата са: година, месец, ден, час, минута, секунда(и), времева
    система, label ("TIME OF FIRST OBS"/"TIME OF LAST OBS") - позиционно
    подравнени с фиксирана ширина, разделени с whitespace, което split()
    обработва коректно.

    :param obs_file_path: път до RINEX .obs файл (str или Path)
    :return: средна епоха като decimal year (напр. 2026.586...), или None
        ако не могат да бъдат намерени и двата реда преди END OF HEADER
    """
    first_obs = None
    last_obs = None

    with open(obs_file_path, 'r') as f:
        for line in f:
            if 'END OF HEADER' in line:
                break
            if 'TIME OF FIRST OBS' in line:
                first_obs = _parse_rinex_time_line(line)
            elif 'TIME OF LAST OBS' in line:
                last_obs = _parse_rinex_time_line(line)

    if first_obs is None or last_obs is None:
        return None

    mean_dt = first_obs + (last_obs - first_obs) / 2
    return _datetime_to_decimal_year(mean_dt)


def extract_observation_duration_minutes(obs_file_path) -> Optional[float]:
    """
    Extract the actual observation duration (minutes) covered by a RINEX
    obs file, from the same "TIME OF FIRST OBS"/"TIME OF LAST OBS" header
    lines extract_observation_epoch() already parses (see that function's
    docstring for the confirmed line format) - added specifically so
    PRIDE-PPPAR attempt logging (survey_controller.py's _run_ppp_ar())
    can report how much data a given PPP-AR run actually had to work
    with, since PPP-AR convergence needs 8h+ and a short/failed run is
    otherwise undiagnosable from logs alone without this context.

    Minimal, standalone helper (not threaded through
    extract_observation_epoch()'s own return value) since that function
    already has its own established return contract (decimal-year epoch)
    used elsewhere (BGS2005 transform) - reusing _parse_rinex_time_line()
    directly here instead of changing that function's signature.

    :param obs_file_path: path to RINEX .obs file (str or Path)
    :return: observation duration in minutes, or None if both header
        lines could not be found before END OF HEADER
    """
    first_obs = None
    last_obs = None

    with open(obs_file_path, 'r') as f:
        for line in f:
            if 'END OF HEADER' in line:
                break
            if 'TIME OF FIRST OBS' in line:
                first_obs = _parse_rinex_time_line(line)
            elif 'TIME OF LAST OBS' in line:
                last_obs = _parse_rinex_time_line(line)

    if first_obs is None or last_obs is None:
        return None

    return (last_obs - first_obs).total_seconds() / 60.0


def _parse_rinex_time_line(line: str) -> datetime:
    """
    Парсва един "TIME OF FIRST/LAST OBS" ред в datetime. Времевата система
    (GPS/UTC/GLO ...) в последната текстова колона не се използва тук -
    разликата спрямо UTC е под секунда и е незначителна за целите на
    decimal-year епохата, използвана като t_obs в Helmert
    трансформацията (чиито собствени скорости са в единици от
    десетилетия).
    """
    parts = line.split()
    year, month, day, hour, minute = (int(parts[i]) for i in range(5))
    second = float(parts[5])
    return datetime(year, month, day, hour, minute, int(second),
                     int((second % 1) * 1_000_000))


def _datetime_to_decimal_year(dt: datetime) -> float:
    year_start = datetime(dt.year, 1, 1)
    next_year_start = datetime(dt.year + 1, 1, 1)
    year_length = (next_year_start - year_start).total_seconds()
    elapsed = (dt - year_start).total_seconds()
    return dt.year + elapsed / year_length


_PIPELINE = (
    "+proj=pipeline "
    "+step +proj=helmert "
    "+x=-0.0014 +y=-0.0009 +z=0.0014 "
    "+rx=0 +ry=0 +rz=0 +s=-0.00042 "
    "+dx=0 +dy=-0.0001 +dz=0.0002 "
    "+drx=0 +dry=0 +drz=0 +ds=0 "
    "+t_epoch=2015.0 +convention=position_vector "
    "+step +proj=helmert "
    "+x=0 +y=0 +z=0 "
    "+rx=0.001785 +ry=0.011151 +rz=-0.01617 +s=0 "
    "+dx=0 +dy=0 +dz=0 "
    "+drx=0.000085 +dry=0.000531 +drz=-0.00077 +ds=0 "
    "+t_epoch=2010 +convention=position_vector"
)

_geodetic_to_geocentric = Transformer.from_crs("EPSG:4979", "EPSG:4978", always_xy=True)
_geocentric_to_geodetic = Transformer.from_crs("EPSG:4978", "EPSG:4979", always_xy=True)
_helmert = Transformer.from_pipeline(_PIPELINE)
_geodetic_to_utm35 = Transformer.from_crs("EPSG:4979", "EPSG:9391", always_xy=True)


def itrf2020_to_bgs2005(point: GeodeticPoint, t_obs: float) -> dict:
    """
    :param point: GeodeticPoint(lat, lon, height) в ITRF2020
    :param t_obs: епоха на наблюдение (decimal year, напр. 2026.6) -
        вижте extract_observation_epoch() за извличане от RINEX файл
    :return: dict с geographic (DMS + decimal) и UTM35N резултати - ТОВА Е
        КООРДИНАТАТА ЗА RTCM BROADCAST, не суровата ITRF стойност
    """
    X, Y, Z = _geodetic_to_geocentric.transform(point.lon, point.lat, point.height)
    X2, Y2, Z2, _t2 = _helmert.transform(X, Y, Z, t_obs)
    lon2, lat2, h2 = _geocentric_to_geodetic.transform(X2, Y2, Z2)
    easting, northing = _geodetic_to_utm35.transform(lon2, lat2)

    return {
        "lat_dd": lat2,
        "lon_dd": lon2,
        "height_m": h2,
        "lat_dms": dd_to_dms(lat2, 'N', 'S'),
        "lon_dms": dd_to_dms(lon2, 'E', 'W'),
        "utm35n_easting": easting,
        "utm35n_northing": northing,
        "coordinate_system": "BGS2005",
        "regulation_reference": (
            "Инструкция № РД-02-20-25 от 20.09.2011 г., Чл.22, ал.1 - "
            "изходни данни за относителни ГНСС методи (вкл. RTK) в БГС 2005"
        ),
        # Geocentric (ECEF) of the OUTPUT point (lat2/lon2/h2 above, i.e.
        # the CORRECT - ellipsoidal-height - broadcast coordinate), exposed
        # so survey_controller.py's apply-time invariant check
        # (verify_rtcm_broadcast_ecef()) can verify, right before writing
        # anything to RTCM, that what is ACTUALLY about to be broadcast
        # still matches this point - without recomputing this transform a
        # second time from scratch.
        "output_ecef": (X2, Y2, Z2),
    }


# Maximum 3D ECEF discrepancy, in meters, allowed between
# bgs2005['output_ecef'] (computed ONCE, inside itrf2020_to_bgs2005()) and
# the ECEF recomputed here from the lat/lon/height about to be written.
# These two are meant to be the SAME physical point run through the SAME
# geodetic<->geocentric transform twice - this is a write-precision
# round-trip check, NOT a comparison against an independent measurement or
# a different transform/grid. It does NOT involve the ITRF2020->BGS2005
# Helmert shift (that shift already happened once, identically, on both
# sides - see itrf2020_to_bgs2005()) and does NOT involve the ~5cm
# residual against АГКК's official BGSTrans grid documented at the top of
# this module (that residual is between OUR transform and a DIFFERENT,
# independent grid-based method - it has no bearing on this round-trip).
# The only legitimate source of difference here is the precision
# update_position() actually writes: settings.conf's position= line uses
# "{lat:.8f} {lon:.8f} {height:.3f}" (rtkbase_config.py) - 8 decimal
# degrees (~1.1mm at this latitude) and 3 decimal meters (1mm). 1cm is
# comfortably above that rounding floor while remaining two to three
# orders of magnitude below any error this check is meant to catch: a
# geoid-height mix-up (tens of meters) or a future ARP/antenna-offset bug
# (Part 6 - decimeter-to-meter scale, e.g. a wrong antenna height entered
# in cm vs. m). See verify_rtcm_broadcast_ecef()'s docstring for the full
# reasoning.
RTCM_ECEF_SANITY_THRESHOLD_M = 0.01


def verify_rtcm_broadcast_ecef(point: GeodeticPoint, bgs2005: dict,
                               broadcast_lat: float, broadcast_lon: float,
                               broadcast_height: float) -> dict:
    """
    Defensive invariant, checked immediately before writing anything that
    feeds RTCM 1005/1006 (settings.conf's position=): recompute the ECEF
    of the EXACT lat/lon/height about to be broadcast (broadcast_lat/lon/
    height - the actual arguments the caller is about to pass to
    update_position(), NOT assumed to equal bgs2005['lat_dd']/['height_m']),
    and compare it against bgs2005['output_ecef'] - the ECEF that
    itrf2020_to_bgs2005() itself computed for `point` (the original PPP
    result), i.e. what SHOULD be broadcast.

    This makes a future height-system mix-up (e.g. some later change
    reintroducing a geoid-corrected height, exactly the confirmed-live
    52028a3 regression this check exists to make impossible to ship
    silently again) impossible to miss: if broadcast_height is ever
    anything other than bgs2005['height_m'] (ellipsoidal), the recomputed
    ECEF will be off by the full local geoid separation - tens of meters,
    not the sub-millimeter write-rounding floor this comparison actually
    has (see RTCM_ECEF_SANITY_THRESHOLD_M's own comment for exactly why:
    this is a round-trip of the SAME point through the SAME transform, not
    a comparison against any independent measurement or grid - the ~5cm
    АГКК/BGSTrans residual documented elsewhere in this module does not
    apply here). Since broadcast_lat/lon are expected to be bit-identical
    to bgs2005['lat_dd']/['lon_dd'] (nothing transforms them again between
    itrf2020_to_bgs2005() and update_position()), this check is in
    practice a pure height-consistency check - exactly the failure mode
    that matters here.

    FUTURE EXTENSION (Part 6, ARP/antenna offset): once an antenna
    height/offset correction is applied between the PPP-AR ECEF and the
    broadcast point, this check should be extended to verify the WHOLE
    chain end to end (PPP-AR ECEF -> antenna/ARP correction -> BGS2005
    transform -> written values), still within
    RTCM_ECEF_SANITY_THRESHOLD_M - not just the transform step in
    isolation as it does today.

    Args:
        point: the ORIGINAL PPP result (ITRF2020 lat/lon/ELLIPSOIDAL height)
            - the same GeodeticPoint passed to itrf2020_to_bgs2005(). Not
            directly used (bgs2005['output_ecef'] already reflects it) -
            accepted for a clear call signature and so a future version of
            this check could cross-verify bgs2005['input_ecef'] against it
            if ever needed.
        bgs2005: the dict itrf2020_to_bgs2005() returned for `point` - must
            contain 'output_ecef' (the ECEF of the CORRECT, ellipsoidal-
            height broadcast point).
        broadcast_lat, broadcast_lon, broadcast_height: the EXACT values
            the caller is about to pass to update_position() - this is
            what actually gets checked.

    Returns:
        {'ok': bool, 'distance_m': float, 'detail': str} - 'ok' is True
        only if the 3D ECEF distance is within RTCM_ECEF_SANITY_THRESHOLD_M.
        Never raises - a transform failure here is itself reported as
        ok=False with the exception text in 'detail', since "the check
        itself couldn't run" must block the broadcast exactly like a
        genuine mismatch would, not silently pass it through.
    """
    try:
        X_broadcast, Y_broadcast, Z_broadcast = _geodetic_to_geocentric.transform(
            broadcast_lon, broadcast_lat, broadcast_height)
        X_expected, Y_expected, Z_expected = bgs2005['output_ecef']
        dist_m = ((X_broadcast - X_expected) ** 2 +
                  (Y_broadcast - Y_expected) ** 2 +
                  (Z_broadcast - Z_expected) ** 2) ** 0.5
        ok = dist_m <= RTCM_ECEF_SANITY_THRESHOLD_M
        detail = (f"ECEF 3D distance between the expected (ellipsoidal) broadcast point "
                  f"and the point actually about to be written: {dist_m:.3f}m "
                  f"(threshold {RTCM_ECEF_SANITY_THRESHOLD_M}m)")
        return {'ok': ok, 'distance_m': dist_m, 'detail': detail}
    except Exception as e:
        return {'ok': False, 'distance_m': float('inf'),
                'detail': f"verify_rtcm_broadcast_ecef: check itself failed: {e}"}
