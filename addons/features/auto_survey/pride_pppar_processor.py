"""
PRIDE-PPPAR Ambiguity-Resolution PPP Processor
================================================

Optional, alternate FINAL-tier PPP backend using PRIDE-PPPAR's `pdp3`
(Wuhan University, IGS Pilot Project PPP-AR) instead of RTKLIB's rnx2rtkp
(see ppp_processor.py). Unlike rnx2rtkp -p 8 (float-ambiguity only, per
Pesho's explicit "no PPP-AR without a simple RTKLIB-native option" decision
- see ppp_processor.py's module docstring), PRIDE-PPPAR performs real
ambiguity resolution (integer fixing), at the cost of a heavier, separately
installed toolchain and a materially different output file format.

WIRED INTO survey_controller.py as an opt-in, END-OF-SURVEY-ONLY final AR
step (see SurveyController._run_ppp_ar()) - NOT run on every interim
update, per Pesho's explicit RAM-budget instruction for this station.

INSTALLATION ASSUMPTION (station-side, not managed by this module or
install.sh): PRIDE-PPPAR is installed at ~/.PRIDE_PPPAR_BIN with that
directory added to PATH via .bashrc, and its `pdp3` orchestration binary
is therefore discoverable via shutil.which() in an interactive/login shell
- this module relies on that assumption via find_pdp3() below, mirroring
spp_processor.py's find_rtklib_tool() PATH-first discovery pattern.

CONFIRMED LIVE CLI (BaseStation): `pdp3 -m S <obs-file>` - static mode,
single positional argument (the obs file's own basename, resolved relative
to cwd). NOT the earlier placeholder shape (config-file-then-obs-file) -
that guess is now replaced by this confirmed invocation. No config_template
override is needed for the base use case: pdp3's own default config at
~/.PRIDE_PPPAR_BIN already has "Product directory = Default" (auto-
download of SP3/CLK/OSB/ERP from bdspride.com on every run) and default
Ambiguity fixing = LAMBDA+AI validation - so process_ppp_ar() below does
NOT accept or forward sp3_file/clk_file to pdp3 at all (confirmed: pdp3
does not take them as arguments, unlike rnx2rtkp), and does not require a
config_template_path either, though one may still be passed through for
an advanced override if ever needed.

CRITICAL: pdp3 MUST be invoked via `bash -c "ulimit -s unlimited; exec
pdp3 ..."`, never as a direct subprocess argv list. A confirmed live stack
overflow bug in pdp3 requires the enlarged stack ulimit to be set in the
SAME shell process that execs pdp3 - a Python-side resource.setrlimit()
call would not reliably reach pdp3's own linked Fortran runtime the same
way a shell-level `ulimit -s unlimited` does, and was not what was tested/
confirmed working. Do not "simplify" this to a plain argv subprocess call.

OUTPUT FORMAT - FUNDAMENTALLY DIFFERENT FROM ppp_processor.py's .pos FILE:
PRIDE-PPPAR writes its result to a `pos_<mjd><doy>_<mark>`-style file (e.g.
pos_2020001_abmf). CONFIRMED LIVE (BaseStation, manual pdp3 repro): the
real location is work_dir/<year>/<doy>/pos_* (a 4-digit year, then a
3-digit day-of-year subdirectory that pdp3 itself creates) - e.g.
work_dir/2026/215/pos_2026215_topo - NOT directly under work_dir. This
also matches an earlier manual pdp3 test's directory structure
(~/pdp3_manual_test2/2026/267/), so it's pdp3's normal, consistent
behavior, not a one-off. process_ppp_ar() searches work_dir/<year>/<doy>/
first (the confirmed real location, year/doy taken from pdp3's own
"ProcessSingleSession from <year> <doy> ..." stdout line), then falls
back to work_dir itself, then work_dir/results/ (recursively, one level) -
see process_ppp_ar()'s own comment for the full, current search order.
The file has a variable-length header (config echo) ended by a literal
"END OF HEADER" line, followed by exactly ONE data line with space-
separated columns:

    Name Mjd X Y Z Sx Sy Sz Rxy Rxz Ryz Sig0 Nobs

X/Y/Z are ECEF coordinates in METERS - NOT geodetic lat/lon/height like
rnx2rtkp's .pos output. survey_controller.py's downstream pipeline
(geoid_corrector.py / bgs2005_transformer.py) expects geodetic lat/lon/
height, so parse_ppp_ar_result() below performs an explicit ECEF->geodetic
conversion before returning - this is a REQUIRED conversion step, not
optional/cosmetic, unlike ppp_processor.py's rnx2rtkp path which already
receives geodetic output natively.

AR FIX RATE (NOT a binary fixed/float flag): pdp3 --help documents no
explicit "AR fixed" flag, and the pos_* file's data line carries none
either (confirmed by the column list above). Instead, PRIDE-PPPAR reports
its wide-lane/narrow-lane ambiguity fix rate in stdout as an "Integer
rounding" line, e.g.:

    mGWide/Narrow-lane FR(ind): 88 90 90 100.0% 97.8%

parsed by _parse_fix_rate_line() below into wl_fix_rate/nl_fix_rate
(floats, percent, or None if the line is not found in stdout) - this
replaces the earlier ar_fixed boolean/_detect_ar_fixed() heuristic
entirely, now that a real, confirmed stdout line is available instead of
a guessed marker search.
"""

import logging
import os
import re
import shutil
import subprocess
from datetime import datetime, timedelta
from pathlib import Path
from typing import Dict, List, Optional

logger = logging.getLogger(__name__)

try:
    from addons import dns_health       # DNS vs. transfer error classification
except ImportError:
    try:
        import dns_health
    except ImportError:
        dns_health = None

# Literal marker line PRIDE-PPPAR's pos_* file uses to separate its header
# (config echo - not parsed here) from the single data line that follows
# it. Matched via exact-text membership check, not a regex, per Pesho's
# "exact match on the literal text" instruction.
_END_OF_HEADER_MARKER = "END OF HEADER"

# pos_* result file naming convention (e.g. pos_2020001_abmf) - used only
# to locate the newest matching file in work_dir after pdp3 runs, not to
# extract fields from the name itself (all real fields come from the
# parsed data line).
_POS_FILE_GLOB = "pos_*"

# WGS84 ellipsoid parameters - identical constants to the ones already
# used for the opposite (geodetic->ECEF) conversion in gnss_parser.py's
# GNSSEpoch.to_ecef(), kept consistent with that existing in-repo
# precedent rather than introducing a different source/library for the
# same ellipsoid. pyproj IS already a project dependency (web_app/
# requirements.txt, used by bgs2005_transformer.py for its own geodetic<->
# geocentric transforms) - but a plain closed-form WGS84 conversion here,
# matching gnss_parser.py's existing style, avoids adding a pyproj
# dependency to addons/requirements.txt (this feature's own, currently
# pyproj-free, requirements file) for a single conversion this small.
_WGS84_A = 6378137.0  # semi-major axis, meters
_WGS84_F = 1.0 / 298.257223563  # flattening
_WGS84_E2 = 2 * _WGS84_F - _WGS84_F * _WGS84_F  # first eccentricity squared


class PridePpparProcessorError(Exception):
    """Base class for all pride_pppar_processor errors."""


class Pdp3NotFoundError(PridePpparProcessorError):
    """
    pdp3 was not found on PATH. Raised instead of a generic
    FileNotFoundError, matching ppp_processor.py's AntexNotFoundError
    precedent of surfacing setup problems with an actionable message
    rather than a bare exception.
    """


def find_pdp3() -> Optional[Path]:
    """
    Locate the pdp3 binary via PATH first, matching spp_processor.py's
    find_rtklib_tool() PATH-first discovery convention, then falling back
    to the well-known fixed install location (~/.PRIDE_PPPAR_BIN/pdp3)
    directly if PATH lookup fails.

    THE FALLBACK EXISTS BECAUSE OF A CONFIRMED LIVE PRODUCTION BUG: an
    operator's own interactive shell has ~/.PRIDE_PPPAR_BIN in PATH via
    .bashrc, so a manual `pdp3 -m S ...` test succeeds - but
    rtkbase_web.service (which actually runs this code in production)
    runs as a systemd service, which NEVER sources .bashrc, so
    shutil.which("pdp3") always returned None there even though pdp3 was
    genuinely installed - confirmed via live journalctl on BaseStation
    ("PPP-AR enabled but pdp3 not available - skipping this run: pdp3 not
    found on PATH" on every single PPP-AR attempt, interim and finalize
    alike, of a real test survey). The primary fix for this is
    unit/rtkbase_web.service's own Environment=PATH= line (added
    alongside this fallback, substituted with the install user's real
    home directory by tools/copy_unit.sh) - this fallback is defensive
    belt-and-suspenders for any station where that unit file substitution
    didn't take effect (e.g. a manually edited/stale unit file), NOT the
    primary mechanism.

    The fixed location checked is os.path.expanduser("~/.PRIDE_PPPAR_BIN/pdp3")
    - i.e. the HOME of whatever user this code is currently running as
    (root, when run via rtkbase_web.service), NOT any specific installer
    username. This matches PRIDE-PPPAR's own documented install
    convention (~/.PRIDE_PPPAR_BIN) without hardcoding any specific
    other username.

    Returns:
        Path to pdp3, or None if not found by either method.
    """
    tool_path = shutil.which("pdp3")
    if tool_path:
        logger.info(f"find_pdp3: found pdp3 at {tool_path} (via PATH)")
        return Path(tool_path)

    logger.debug("find_pdp3: pdp3 not found via PATH - checking fixed fallback location")

    fallback_path = Path(os.path.expanduser("~/.PRIDE_PPPAR_BIN/pdp3"))
    if fallback_path.exists():
        logger.info(f"find_pdp3: found pdp3 at {fallback_path} "
                    f"(via fixed fallback location, NOT PATH - PATH lookup failed first)")
        return fallback_path

    logger.warning(
        f"find_pdp3: pdp3 not found - checked PATH (shutil.which) and "
        f"fixed fallback location ({fallback_path}, which does not exist). "
        f"Current PATH={os.environ.get('PATH', '(unset)')!r}. "
        f"If PRIDE-PPPAR is installed, verify unit/rtkbase_web.service's "
        f"Environment=PATH= line was applied (tools/copy_unit.sh + "
        f"systemctl daemon-reload + service restart)."
    )
    return None


def _ecef_to_geodetic(x: float, y: float, z: float) -> Dict[str, float]:
    """
    Convert ECEF (X, Y, Z, meters) to geodetic (lat, lon, height) on the
    WGS84 ellipsoid, via Bowring's iterative method - a standard,
    textbook closed-form-seeded iteration, not a novel derivation.

    Chosen over an external library (pyproj is available elsewhere in
    this project - see the module-level comment above - but not currently
    a dependency of addons/requirements.txt) since a single, well-known
    ECEF->geodetic formula this small does not warrant adding one here.

    Args:
        x, y, z: ECEF coordinates, meters

    Returns:
        Dict with 'lat' (degrees), 'lon' (degrees), 'height' (meters)
    """
    import math

    a = _WGS84_A
    e2 = _WGS84_E2
    b = a * math.sqrt(1 - e2)

    lon = math.atan2(y, x)

    p = math.sqrt(x * x + y * y)

    # Initial latitude guess (spherical approximation), then iterate to
    # convergence - standard Bowring-style iteration, typically converges
    # in a handful of iterations for terrestrial-range coordinates.
    lat = math.atan2(z, p * (1 - e2))
    for _ in range(10):
        sin_lat = math.sin(lat)
        N = a / math.sqrt(1 - e2 * sin_lat * sin_lat)
        h = p / math.cos(lat) - N
        lat_new = math.atan2(z, p * (1 - e2 * N / (N + h)))
        if abs(lat_new - lat) < 1e-12:
            lat = lat_new
            break
        lat = lat_new

    sin_lat = math.sin(lat)
    N = a / math.sqrt(1 - e2 * sin_lat * sin_lat)
    height = p / math.cos(lat) - N

    return {
        'lat': math.degrees(lat),
        'lon': math.degrees(lon),
        'height': height,
    }


# Confirmed live stdout line format (BaseStation), e.g.:
#   mGWide/Narrow-lane FR(ind): 88 90 90 100.0% 97.8%
# Captures the two trailing percentage fields as wide-lane/narrow-lane fix
# rates - the "FR(ind)" label and the three leading integer counts (fixed/
# total-ish counters) are not otherwise parsed here, only the two percent
# values, which are what _run_ppp_ar()'s fix-rate threshold check (in
# survey_controller.py) actually consumes.
_FIX_RATE_LINE_RE = re.compile(
    r'Wide/Narrow-lane\s+FR\(ind\):\s*\d+\s+\d+\s+\d+\s+'
    r'([\d.]+)%\s+([\d.]+)%',
    re.IGNORECASE
)

# Confirmed live stdout line format (BaseStation), e.g.:
#   ===> ProcessSingleSession from 2026 215 to 2026 215 ...
# pdp3's own stated processing year/day-of-year - used to locate its
# result file at work_dir/<year>/<doy>/pos_* (see module docstring's
# OUTPUT FORMAT section), since this is pdp3's own record of what it
# actually used, rather than something inferred separately (e.g. from the
# obs file's RINEX header) that could drift out of sync with it. Captures
# only the first (year, doy) pair - a session spanning a day boundary
# would still have created its output under the FIRST day's subdirectory,
# matching pdp3's own "from <year> <doy>" (not "to") semantics.
_PROCESS_SESSION_LINE_RE = re.compile(
    r'ProcessSingleSession\s+from\s+(\d{4})\s+(\d{1,3})\b'
)


def _parse_process_session_year_doy(stdout: str) -> Optional[tuple]:
    """
    Parse pdp3's "===> ProcessSingleSession from <year> <doy> to ..."
    stdout line to recover the (year, doy) it actually processed under.

    Args:
        stdout: pdp3's captured stdout

    Returns:
        (year, doy) as (str, str), doy zero-padded to 3 digits to match
        pdp3's own work_dir/<year>/<doy>/ directory naming - or None if
        the line was not found (not an error; callers must fall back to
        the other search locations, see process_ppp_ar()).
    """
    match = _PROCESS_SESSION_LINE_RE.search(stdout)
    if not match:
        return None
    year, doy = match.group(1), match.group(2)
    return year, doy.zfill(3)


# Receiver-agnostic frequency combination selection for pdp3's -frq option.
#
# pdp3's own default (G12 R12 E15 C26 J12) assumes a receiver tracking
# Galileo E5a and BeiDou B3I. Confirmed live (ZED-F9P station, doy 272): the
# F9P records only E1+E5b and B1I+B2I, so with the defaults every Galileo
# and BeiDou satellite was unusable and ambiguity resolution ran on GPS
# alone. A UM980 does track E5a/B3I, so no single fixed combination suits
# both receivers - instead the combination is chosen per run from the obs
# file itself: its "SYS / # / OBS TYPES" header, plus a short scan of the
# first epochs to count satellites that actually carry both bands.
#
# Digits are RINEX 3.03+ band numbers (G: 1=L1 2=L2 5=L5; E: 1=E1 5=E5a
# 7=E5b 6=E6 8=E5ab; C: 2=B1I 6=B3I 7=B2I/B2b 1=B1C 5=B2a 8=B2ab). The valid
# digit sets below are copied verbatim from pdp3.sh's own -frq validation (G
# "125", R "12", E "15678", C "125678", J "1256") so we can never emit a
# combination pdp3 would reject.
#
# Priority = prefer pairs whose phase biases WUM products carry (AR-capable),
# then any other valid pair present. Verified against the vendored PRIDE
# 3.2.11 source rather than assumed:
#   - Within a band, pdp3's RINEX reader (src/lib/rdrnxoi3.f90) prefers any
#     tracking code that HAS an OSB in the product over one that doesn't, so
#     we choose bands only - we don't need to steer it toward specific
#     tracking codes (e.g. UM980's C1C vs C1L).
#   - src/lib/read_bias.f90 fills a missing phase bias from another tracking
#     code on the SAME frequency ("assumes phase biases on the same
#     frequency are identical"), so F9P's Galileo L1X/L7X get the product's
#     L1C/L7Q biases - E17 is AR-capable.
#   - C27 (B1I+B2I) is expected to be FLOAT-ONLY on the F9P. Confirmed from
#     the doy-272 obs file: of 19 BeiDou satellites only C09 (a BDS-2 IGSO)
#     carries any L7I data. BDS-3 satellites don't broadcast B2I (their
#     1207.14 MHz signal is B2b), so the same-frequency fill above has
#     nothing to bridge, and the one BDS-2 satellite has no B2I bias in WUM
#     products. In practice the minimum-satellite rule below excludes F9P
#     BeiDou entirely.
#   - PRIDE 3.2.11 processes dual-frequency ionosphere-free combinations
#     only ("all-frequency PPP-AR on any dual-frequency ionosphere-free
#     combinations", CHANGELOG) - there is no triple-frequency/uncombined
#     mode to exploit for the UM980's extra bands.
_PDP3_VALID_BANDS = {'G': '125', 'R': '12', 'E': '15678', 'C': '125678', 'J': '1256'}
_FREQ_PRIORITY = {
    'G': ['12', '15'],
    'R': ['12'],
    'E': ['15', '17', '16'],
    'C': ['26', '27'],
    'J': ['12', '15'],
}
# Fallback beyond _FREQ_PRIORITY: pair one upper L-band signal (~1.56-1.60
# GHz) with one lower L-band signal (~1.17-1.28 GHz), in the order listed.
# Never two bands from the same region (e.g. C12 = B1C+B1I, E57 = E5a+E5b):
# their frequencies are so close that the ionosphere-free combination
# amplifies noise enormously, even though pdp3 would accept the digits.
_UPPER_BANDS = {'G': '1', 'R': '1', 'E': '1', 'C': '21', 'J': '1'}
_LOWER_BANDS = {'G': '25', 'R': '2', 'E': '5768', 'C': '6758', 'J': '256'}
# A constellation with fewer satellites than this carrying BOTH chosen
# bands is excluded: it contributes almost no geometry but still costs an
# inter-system bias parameter.
_MIN_SATS_PER_SYSTEM = 4
# The satellite count only needs a representative sample, not the whole
# (possibly 24h, 1 Hz) file - scan the first 30 minutes of epochs.
_SAT_SCAN_SECONDS = 1800
# Used only if the obs file can't be used at all - suits the F9P, the
# receiver we have live evidence for (pdp3's own defaults suit neither
# receiver better, and are silently wrong for the F9P).
_FREQ_FALLBACK = ['G12', 'R12', 'E17', 'C27']
_OBS_TYPES_LABEL = 'SYS / # / OBS TYPES'


def _bds_band(band: str, rinex_version: float) -> str:
    """
    RINEX 3.00-3.02 numbered BeiDou B1I as band 1 (C1I/L1I); 3.03+ uses
    band 2, and band 1 became B1C. Map old files onto the 3.03+ numbering
    used everywhere in this module (and by pdp3's -frq). pdp3 itself does
    the reverse lookup when reading a 3.02 file (rdrnxoi3.f90: "if C and
    ver == 302 and band 2 -> 1"), so passing C2x for such a file is right.
    """
    return '2' if (band == '1' and rinex_version < 3.03) else band


def _read_obs_file_info(obs_file: Path) -> Optional[Dict]:
    """
    Read what frequency selection needs from a RINEX 3/4 obs file:
        'version': e.g. 3.04
        'types':   {system: ['C1C', 'L1C', ...]} from "SYS / # / OBS TYPES"
                   (handles continuation lines - a UM980 always has >13)
        'epoch_bands': {system: {prn: [set_of_bands, ...]}} - one set per
                   epoch: the bands on which that satellite had a non-blank
                   phase value in that epoch. Kept per epoch so a pair is
                   only credited if both bands appeared in the SAME epoch.
                   Only the first _SAT_SCAN_SECONDS of data are scanned.
        'epochs_scanned': int
    BeiDou bands are already remapped to 3.03+ numbering (_bds_band).
    Returns None if the file isn't RINEX 3/4 or has no obs-type lines.
    """
    types: Dict[str, List[str]] = {}
    current = None
    with open(obs_file, 'r', errors='replace') as f:
        first = f.readline()
        try:
            version = float(first[:9])
        except ValueError:
            return None
        if not 3.0 <= version < 5.0:
            return None
        for line in f:
            label = line[60:].strip()
            if label == 'END OF HEADER':
                break
            if label != _OBS_TYPES_LABEL:
                continue
            if line[0] != ' ':
                current = line[0]
                types[current] = []
            if current is not None:
                types[current].extend(line[7:60].split())
        if not types:
            return None

        # Column index -> band, for phase observations only.
        phase_cols = {
            s: [(i, _bds_band(t[1], version) if s == 'C' else t[1])
                for i, t in enumerate(ts) if len(t) == 3 and t[0] == 'L']
            for s, ts in types.items()
        }
        # {system: {prn: [set_of_bands_per_epoch, ...]}}
        epoch_bands: Dict[str, Dict[str, List[set]]] = {s: {} for s in types}
        epochs, t0 = 0, None
        pending = 0          # satellite lines still to read for this epoch
        skip = 0             # special-event lines to skip
        for line in f:
            if skip:
                skip -= 1
                continue
            if line.startswith('>'):
                # RINEX 3 epoch record: "> yyyy mm dd hh mi ss.sssssss  f nnn"
                # year [2:6] .. minute [16:18], seconds [18:29] (F11.7),
                # event flag [31:32], satellite count [32:35].
                try:
                    y, mo, d, h, mi = (int(x) for x in line[2:18].split())
                    t = datetime(y, mo, d, h, mi) + timedelta(seconds=float(line[18:29]))
                    flag = int(line[31:32]) if line[31:32].strip() else 0
                    nsat = int(line[32:35])
                except ValueError:
                    pending = 0
                    continue
                if flag > 1:            # special event: next nsat lines are header records
                    skip, pending = nsat, 0
                    continue
                if t0 is None:
                    t0 = t
                elif (t - t0).total_seconds() > _SAT_SCAN_SECONDS:
                    break
                epochs += 1
                pending = nsat
                continue
            if not pending:
                continue
            pending -= 1
            system, prn = line[0], line[:3]
            cols = phase_cols.get(system)
            if not cols:
                continue
            bands = set()
            for i, band in cols:
                field = line[3 + 16 * i: 3 + 16 * i + 14]
                try:
                    if float(field) != 0.0:
                        bands.add(band)
                except ValueError:
                    pass   # blank = not observed
            if bands:
                epoch_bands[system].setdefault(prn, []).append(bands)

    return {'version': version, 'types': types, 'epoch_bands': epoch_bands,
            'epochs_scanned': epochs}


def _usable_bands(obs_types: List[str], system: str, version: float) -> str:
    """Bands with BOTH a code and a phase observation - pdp3 needs both."""
    def band(t):
        return _bds_band(t[1], version) if system == 'C' else t[1]
    code = {band(t) for t in obs_types if len(t) == 3 and t[0] == 'C'}
    phase = {band(t) for t in obs_types if len(t) == 3 and t[0] == 'L'}
    return ''.join(sorted(code & phase))


def _sats_with_pair(epoch_bands: Dict[str, List[set]], pair: str) -> int:
    """Satellites that had BOTH bands of `pair` in at least one epoch."""
    need = set(pair)
    return sum(1 for per_epoch in epoch_bands.values() if any(need <= b for b in per_epoch))


def _fallback(reasons: Dict[str, str], why: str, bands=None) -> Dict:
    return {'frq': list(_FREQ_FALLBACK), 'sys': None, 'bands': bands or {},
            'sat_counts': {}, 'reasons': {**reasons, '*': why}, 'fallback': True}


def select_frequency_combination(obs_file: Path) -> Dict:
    """
    Pick pdp3's -frq combination (and matching -sys constellation list)
    from the obs file itself. See _FREQ_PRIORITY above for the rationale
    and the verification behind it.

    Per constellation: walk the candidate pairs (_FREQ_PRIORITY, then the
    upper x lower fallback) and take the first whose two bands are in the
    header AND are carried together by at least _MIN_SATS_PER_SYSTEM
    satellites in the first _SAT_SCAN_SECONDS of data. If none qualifies,
    the constellation is excluded (reason logged).

    Returns a dict:
        'frq': e.g. ['G12', 'R12', 'E17'] - passed as `-frq ...`
        'sys': e.g. 'GRE', or None to leave pdp3's constellation set alone
               (only on fallback). Needed because pdp3 fills in its default
               combination for any constellation missing from -frq, so
               omitting one from -frq does NOT exclude it.
        'bands': {system: usable band digits from the header}
        'sat_counts': {system: satellites carrying the chosen pair}
        'reasons': {system: human-readable reason for its choice}
        'fallback': True if the obs file couldn't be used
    """
    try:
        info = _read_obs_file_info(obs_file)
    except OSError as e:
        logger.warning(f"select_frequency_combination: could not read {obs_file}: {e}")
        info = None

    if not info:
        return _fallback({}, 'obs header not parseable (not RINEX 3/4 or no '
                             f'"{_OBS_TYPES_LABEL}" lines) - using fallback')

    # If the body scan found no epochs at all, a satellite count of zero
    # would say nothing about the data - skip the minimum-satellite rule
    # rather than exclude every constellation on a parsing technicality.
    count_sats = info['epochs_scanned'] > 0
    reasons: Dict[str, str] = {}
    if not count_sats:
        reasons['*'] = 'no epochs found in the first scan window - minimum-satellite check skipped'
    if info['version'] < 3.03 and 'C' in info['types']:
        reasons['C-version'] = (f"RINEX {info['version']:.2f}: BeiDou band 1 read as B1I "
                                "(remapped to 3.03+ band 2)")

    frq, bands, sat_counts = [], {}, {}
    for system, valid in _PDP3_VALID_BANDS.items():
        if system not in info['types']:
            continue
        present = ''.join(b for b in _usable_bands(info['types'][system], system, info['version'])
                          if b in valid)
        bands[system] = present
        preferred = _FREQ_PRIORITY[system]
        candidates = preferred + [u + l for u in _UPPER_BANDS[system] for l in _LOWER_BANDS[system]
                                  if u + l not in preferred]
        chosen, rejected = None, []
        for c in candidates:
            if c[0] not in present or c[1] not in present:
                continue
            n = _sats_with_pair(info['epoch_bands'].get(system, {}), c) if count_sats else None
            if n is not None and n < _MIN_SATS_PER_SYSTEM:
                rejected.append(f"{system}{c}: {n} sat(s)")
                continue
            chosen = c
            sat_counts[system] = n
            break

        if chosen is None:
            why = (f"only {', '.join(rejected)} carrying both bands (< {_MIN_SATS_PER_SYSTEM})"
                   if rejected else "no usable dual-band pair")
            reasons[system] = f"bands {present or 'none'} - {why} - constellation excluded"
            continue

        frq.append(system + chosen)
        before = preferred[:preferred.index(chosen)] if chosen in preferred else preferred
        unavailable = [system + c for c in before if not (c[0] in present and c[1] in present)]
        reasons[system] = (f"bands {present} -> {system}{chosen}"
                           + (f" ({sat_counts[system]} sats)" if sat_counts.get(system) is not None else '')
                           + (f" ({', '.join(unavailable)} not in obs)" if unavailable else '')
                           + (f" (rejected {', '.join(rejected)})" if rejected else '')
                           + ('' if chosen in preferred else ' [outside preferred list - may be float-only]'))

    if not frq:
        return _fallback(reasons, 'no constellation has a usable dual-band pair - using fallback', bands)

    return {'frq': frq, 'sys': ''.join(c[0] for c in frq), 'bands': bands,
            'sat_counts': sat_counts, 'reasons': reasons, 'fallback': False}



def _parse_fix_rate_line(stdout: str) -> Dict[str, Optional[float]]:
    """
    Parse PRIDE-PPPAR's "Integer rounding" wide-lane/narrow-lane fix-rate
    line from pdp3's captured stdout, e.g.:

        mGWide/Narrow-lane FR(ind): 88 90 90 100.0% 97.8%

    Confirmed live wording/format (BaseStation) - replaces the earlier
    ar_fixed boolean/_detect_ar_fixed() heuristic, since pdp3 --help
    documents no explicit binary "AR fixed" flag and the pos_* file's data
    line carries none either (see module docstring's AR FIX RATE section).

    Args:
        stdout: pdp3's captured stdout

    Returns:
        Dict with 'wl_fix_rate' and 'nl_fix_rate' (floats, percent, e.g.
        100.0 and 97.8) - both None if the line is not found in stdout
        (not an error; callers must treat None as "fix rate unknown for
        this run", not as 0%).
    """
    match = _FIX_RATE_LINE_RE.search(stdout)
    if not match:
        logger.warning(
            "Could not find PRIDE-PPPAR's 'Wide/Narrow-lane FR(ind)' fix-"
            "rate line in pdp3 stdout - wl_fix_rate/nl_fix_rate will be "
            "None for this run."
        )
        return {'wl_fix_rate': None, 'nl_fix_rate': None}

    return {
        'wl_fix_rate': float(match.group(1)),
        'nl_fix_rate': float(match.group(2)),
    }


# Matches any pdp3 output line that starts with "error:" or "warning:"
# (case-insensitive, allowing leading whitespace) - pdp3's own
# self-reported diagnostic lines, e.g. "error: PrepareProducts failed" or
# "error: from 2026 268 to 2026 268 processing failed" (both confirmed
# live on BaseStation as the actual cause behind a run that exited 0 with
# no pos_* file - see process_ppp_ar()'s comment on that failure class).
_PDP3_ERROR_LINE_RE = re.compile(r'^\s*(error|warning)\s*:', re.IGNORECASE)


def _log_pdp3_error_lines(stdout: str, stderr: str, level: int = logging.WARNING) -> None:
    """
    Extract and log, at the given level (default WARNING - visible in
    normal production logging, unlike the full stdout/stderr dump which
    stays at debug), every line from pdp3's stdout/stderr that looks like
    one of pdp3's own self-reported "error:"/"warning:" diagnostics.

    This is what makes a failed slot's ACTUAL cause (e.g. "failed to
    download satellite clock product") visible in normal production logs
    without needing to enable debug logging or manually reproduce the run
    - confirmed live: pdp3 can exit 0 while having actually failed (see
    process_ppp_ar()'s comment), so its own printed error lines are often
    the ONLY signal of what actually went wrong.

    Logs nothing (silently) if no such lines are found - not itself an
    error condition, since some pdp3 failure modes (e.g. a genuine crash
    with no self-diagnostic output at all) have none to extract; the
    caller's own log line (exit code, or "no pos_* file found") already
    covers that case.
    """
    matched_lines = []
    for stream_name, stream_text in (("stdout", stdout), ("stderr", stderr)):
        if not stream_text:
            continue
        for line in stream_text.splitlines():
            if _PDP3_ERROR_LINE_RE.match(line):
                matched_lines.append(f"[pdp3 {stream_name}] {line.strip()}")

    if matched_lines:
        logger.log(
            level,
            "process_ppp_ar: pdp3 reported the following error/warning line(s), "
            "likely the actual cause of this failed run:\n" + "\n".join(matched_lines)
        )

    _log_download_failure_kinds(f"{stdout or ''}\n{stderr or ''}", level)


# curl/wget failure lines printed by pdp3's product downloads (curl for
# bdspride, wget for igs.gnsswhu.cn and others). They don't start with
# "error:"/"warning:", so _PDP3_ERROR_LINE_RE never surfaced them.
_DOWNLOAD_FAILURE_RE = re.compile(
    r'curl: \(\d+\)|wget: |ERROR \d{3}|failed: |unable to resolve|Failed EPSV|'
    r'421 |550 |Connection (?:timed out|refused)', re.IGNORECASE)


def _log_download_failure_kinds(text: str, level: int) -> None:
    """
    Tell apart "DNS resolution failed" (curl exit 6, or exit 28 with
    "Resolving timed out", wget "unable to resolve host address") from
    server/transfer errors (FTP 421, 550 file not found, connect timeouts,
    stalled data channels). They need different fixes: the first is the
    station's network DNS (see Watchdog > DNS and tools/dns_setup.sh), the
    second is the mirror or the product not being published yet.
    """
    if dns_health is None:
        return
    dns = dns_health.classify_network_error(text)
    other = [l.strip() for l in text.splitlines()
             if _DOWNLOAD_FAILURE_RE.search(l) and l.strip() not in dns['lines']]
    if dns['dns']:
        logger.log(level,
                   f"process_ppp_ar: product download failed on DNS RESOLUTION "
                   f"({len(dns['lines'])} line(s), hosts: {', '.join(dns['hosts']) or 'unknown'}) - "
                   f"the station could not resolve the mirror's name; not a server or transfer error. "
                   f"Check the DNS the station's network provides (Watchdog > DNS). "
                   f"First lines: {dns['lines'][:3]}")
    if other:
        logger.log(level,
                   f"process_ppp_ar: product download server/transfer errors "
                   f"({len(other)} line(s), not DNS): {other[:5]}")


class PridePpparProcessor:
    """
    Process RINEX for PPP-AR positioning using PRIDE-PPPAR's pdp3.

    Constructor shape mirrors PPPProcessor (ppp_processor.py) - accepts
    rtkbase_root for consistency with that class's own convention, though
    (unlike PPPProcessor's ANTEX path) this module has no rtkbase_root-
    relative asset of its own; kept for a consistent construction pattern
    alongside survey_controller.py's self.spp = PPPProcessor(...).

    Wired into survey_controller.py via SurveyController._run_ppp_ar() -
    an opt-in (ppp_ar_enabled, default False), end-of-survey-only step,
    never run per interim update (RAM budget).
    """

    def __init__(self, pdp3_path: Optional[str] = None,
                 rtkbase_root: Optional[Path] = None):
        """
        Args:
            pdp3_path: Path to the pdp3 binary (auto-detected via PATH if
                None, matching PPPProcessor's rnx2rtkp_path convention).
            rtkbase_root: RTKBase installation root - accepted for
                constructor-shape consistency with PPPProcessor, not
                currently used for any path resolution in this class.
        """
        if pdp3_path is None:
            pdp3 = find_pdp3()
            if pdp3 is None:
                raise Pdp3NotFoundError(
                    "pdp3 not found on PATH. PRIDE-PPPAR must be "
                    "installed at ~/.PRIDE_PPPAR_BIN with that directory "
                    "added to PATH (e.g. via .bashrc) before this "
                    "processor can be used."
                )
            self.pdp3 = pdp3
        else:
            self.pdp3 = Path(pdp3_path)
            if not self.pdp3.exists():
                raise Pdp3NotFoundError(f"pdp3 not found at {pdp3_path}")

        if rtkbase_root is None:
            import os
            rtkbase_root = Path(os.path.abspath(
                os.path.join(os.path.dirname(__file__), "../../../")
            ))
        self.rtkbase_root = Path(rtkbase_root)

    def process_ppp_ar(self,
                        obs_file: Path,
                        work_dir: Path) -> Optional[Path]:
        """
        Run PRIDE-PPPAR's pdp3 for ambiguity-resolved PPP-static
        positioning.

        Confirmed live CLI (BaseStation): `pdp3 -m S <obs-file>` - static
        mode, obs-file given by basename, resolved relative to cwd (=
        work_dir here). pdp3 is fully self-contained: it downloads its own
        SP3/CLK/OSB/ERP products from bdspride.com on every run (its
        default config has "Product directory = Default" = auto-download)
        - it does NOT accept sp3_file/clk_file as arguments the way
        rnx2rtkp does, so none are passed here (see module docstring).

        Args:
            obs_file: RINEX observation file. Copied into work_dir first
                if not already located there, since pdp3 resolves its
                obs-file argument relative to cwd (confirmed live
                behavior) - a caller-supplied obs_file living elsewhere
                (e.g. survey_controller.py's rinex_dir) would otherwise
                not be found.
            work_dir: Directory to invoke pdp3 from - REQUIRED, must be a
                real, writable directory. pdp3 downloads its precise
                products and writes its pos_* result file relative to
                this directory (see module docstring's OUTPUT FORMAT
                section). NOT created or cleaned up by this method if it
                already exists - the caller owns its lifecycle, since it
                needs to still exist afterward to locate/read the pos_*
                result file.

        Returns:
            Path to the generated pos_* file, or None on failure/timeout.
        """
        if not obs_file.exists():
            logger.error(f"process_ppp_ar: observation file not found: {obs_file}")
            return None

        logger.info(f"process_ppp_ar: obs_file={obs_file}, work_dir={work_dir}")

        work_dir = Path(work_dir)
        work_dir.mkdir(parents=True, exist_ok=True)

        # pdp3 resolves its obs-file argument relative to cwd (confirmed
        # live) - copy obs_file into work_dir first if it isn't already
        # there, so the basename-only argument below actually resolves.
        local_obs_file = work_dir / obs_file.name
        obs_was_copied = obs_file.resolve() != local_obs_file.resolve()
        if obs_was_copied:
            shutil.copyfile(obs_file, local_obs_file)
            logger.debug(f"process_ppp_ar: copied obs_file into work_dir: "
                         f"{obs_file} -> {local_obs_file}")
        else:
            logger.debug(f"process_ppp_ar: obs_file already in work_dir, no copy needed: {local_obs_file}")

        # Frequency combination chosen per run from the obs header, so the
        # same code serves both the ZED-F9P and the UM980 (see
        # select_frequency_combination()).
        freq = select_frequency_combination(local_obs_file)
        self._last_freq_selection = freq
        logger.info(
            f"process_ppp_ar: frequency combination {' '.join(freq['frq'])}"
            f"{' (FALLBACK)' if freq['fallback'] else ''}; "
            f"detected bands: {freq['bands'] or 'n/a'}; "
            f"reasons: {'; '.join(f'{k}: {v}' for k, v in freq['reasons'].items())}"
        )

        # Confirmed live CLI: `pdp3 -m S <obs-file>` (static mode), plus the
        # per-run -frq/-sys selection above. No config file, no sp3/clk
        # arguments - see module docstring. The obs file must stay LAST:
        # pdp3's ParseCmdArgs() treats the last argument as the obs file.
        pdp3_args = [str(self.pdp3), "-m", "S", "-frq", *freq['frq']]
        if freq['sys']:
            pdp3_args += ["-sys", freq['sys']]
        pdp3_args.append(local_obs_file.name)

        # CRITICAL: pdp3 must run under an enlarged stack ulimit, set in
        # the SAME shell process that execs it (see module docstring) - a
        # bash -c wrapper with `ulimit -s unlimited; exec pdp3 ...`, not a
        # direct argv subprocess call and not a Python-side
        # resource.setrlimit() call.
        shell_cmd = f"ulimit -s unlimited; exec {' '.join(pdp3_args)}"
        full_command_line = f'bash -c "{shell_cmd}"'

        run_start = datetime.utcnow()
        logger.info(f"process_ppp_ar: starting pdp3 at {run_start.isoformat()}Z")
        logger.info(f"process_ppp_ar: full command line: {full_command_line}")

        try:
            result = subprocess.run(
                ["bash", "-c", shell_cmd],
                cwd=work_dir,
                timeout=2400,
                capture_output=True,
                text=True,
            )
        except subprocess.TimeoutExpired:
            elapsed = (datetime.utcnow() - run_start).total_seconds()
            logger.error(f"process_ppp_ar: pdp3 timeout (>40 minutes) after {elapsed:.1f}s wall-clock")
            return None
        except Exception as e:
            elapsed = (datetime.utcnow() - run_start).total_seconds()
            logger.error(f"process_ppp_ar: pdp3 processing failed after {elapsed:.1f}s: {e}", exc_info=True)
            return None

        elapsed = (datetime.utcnow() - run_start).total_seconds()
        logger.info(f"process_ppp_ar: pdp3 finished, exit_code={result.returncode}, "
                    f"elapsed={elapsed:.1f}s wall-clock")
        # Full stdout/stderr at debug level (not truncated) - volume
        # concern noted, but a malformed/failed pdp3 run is otherwise
        # undiagnosable from logs alone, per this session's explicit
        # requirement. Kept at debug (not shown in default production
        # logging) since it's often large and mostly noise on a SUCCESSFUL
        # run; the warning/error-level summary below (for failed runs
        # specifically) is what makes a failure diagnosable without
        # needing to enable debug logging or reproduce by hand.
        logger.debug(f"process_ppp_ar: FULL stdout:\n{result.stdout}")
        logger.debug(f"process_ppp_ar: FULL stderr:\n{result.stderr}")

        # CONFIRMED LIVE (BaseStation): pdp3 can exit 0 while having
        # actually FAILED (e.g. a product-download failure such as
        # "error: PrepareProducts failed" / "error: from 2026 268 to 2026
        # 268 processing failed") and produced no pos_* file at all - pdp3
        # never signals this failure class via a non-zero exit code. Both
        # failure paths (non-zero exit, and zero-exit-but-no-pos-file,
        # checked further below) therefore need the SAME diagnostic
        # surfacing: pdp3's own "error:"/"warning:" lines, at
        # logger.warning/error (visible in default production logging),
        # not logger.debug - previously an operator had to manually
        # reproduce a failed run by hand to see this same information,
        # since it was only ever logged at debug level.
        if result.returncode != 0:
            logger.error(f"process_ppp_ar: pdp3 failed (exit {result.returncode}): {result.stderr}")
            _log_pdp3_error_lines(result.stdout, result.stderr, level=logging.ERROR)
            return None

        # Search order (first match wins), most-confirmed location first:
        #   1. work_dir/<year>/<doy>/pos_* - CONFIRMED LIVE real location
        #      (BaseStation manual repro): pdp3 creates a
        #      <4-digit-year>/<3-digit-doy>/ subdirectory and writes its
        #      pos_* file there, e.g. work_dir/2026/215/pos_2026215_topo.
        #      year/doy are taken from pdp3's own "===> ProcessSingleSession
        #      from <year> <doy> ..." stdout line (pdp3's own stated
        #      processing date, not inferred separately).
        #   2. work_dir/pos_* - kept as a fallback in case of a different
        #      pdp3 config/version that writes directly to work_dir.
        #   3. work_dir/results/ and work_dir/results/*/ - kept as a
        #      fallback from before the year/doy location was confirmed.
        pos_files = []
        search_locations = []

        year_doy = _parse_process_session_year_doy(result.stdout)
        year_doy_dir = None
        if year_doy is not None:
            year, doy = year_doy
            year_doy_dir = work_dir / year / doy
            search_locations.append(str(year_doy_dir))
            if year_doy_dir.is_dir():
                pos_files = list(year_doy_dir.glob(_POS_FILE_GLOB))
        else:
            logger.warning(
                "process_ppp_ar: could not find pdp3's 'ProcessSingleSession "
                "from <year> <doy>' line in stdout - cannot check the "
                "confirmed work_dir/<year>/<doy>/ location; falling back to "
                "work_dir and work_dir/results only."
            )

        if not pos_files:
            search_locations.append(str(work_dir))
            pos_files = list(work_dir.glob(_POS_FILE_GLOB))

        if not pos_files:
            results_dir = work_dir / "results"
            search_locations.append(str(results_dir))
            if results_dir.is_dir():
                pos_files = list(results_dir.glob(_POS_FILE_GLOB)) + \
                            list(results_dir.glob(f"*/{_POS_FILE_GLOB}"))

        if not pos_files:
            # Log exactly what WAS found in the searched directories, so a
            # naming-convention mismatch (e.g. pdp3 using a different
            # prefix than "pos_") is immediately visible instead of just
            # "nothing found".
            year_doy_dir_contents = (
                sorted(p.name for p in year_doy_dir.iterdir())
                if year_doy_dir is not None and year_doy_dir.is_dir() else
                ('(directory does not exist)' if year_doy_dir is not None else '(year/doy unknown - not searched)')
            )
            work_dir_contents = sorted(p.name for p in work_dir.iterdir()) if work_dir.is_dir() else []
            results_dir = work_dir / "results"
            results_dir_contents = sorted(p.name for p in results_dir.iterdir()) if results_dir.is_dir() else None
            logger.error(
                f"process_ppp_ar: no pos_* result file found. "
                f"Searched: {search_locations}. "
                f"work_dir/<year>/<doy> contents: {year_doy_dir_contents}. "
                f"work_dir contents: {work_dir_contents}. "
                f"work_dir/results contents: "
                f"{results_dir_contents if results_dir_contents is not None else '(directory does not exist)'}"
            )
            # Zero-exit-code-but-actually-failed case (see the comment
            # above the exit-code check) - same diagnostic surfacing as
            # the non-zero-exit path, since this is exactly the class of
            # failure that exit code alone cannot distinguish from
            # success.
            _log_pdp3_error_lines(result.stdout, result.stderr, level=logging.ERROR)
            return None

        if len(pos_files) > 1:
            logger.info(
                f"process_ppp_ar: {len(pos_files)} pos_* candidates found: "
                f"{[str(p) for p in pos_files]}"
            )

        # If multiple pos_* files exist (e.g. a stale file from a prior
        # run reusing the same work_dir), take the most recently modified
        # one - mirrors ppp_processor.py's own nav-file auto-detection
        # tie-break convention (max by mtime).
        pos_file = max(pos_files, key=lambda p: p.stat().st_mtime)

        if len(pos_files) > 1:
            logger.info(f"process_ppp_ar: picked newest by mtime: {pos_file}")

        logger.info(f"✓ PRIDE-PPPAR position file: {pos_file}")

        # Stash stdout on the instance for parse_ppp_ar_result()'s fix-
        # rate parsing to reuse without re-running pdp3 - simplest option
        # given process_ppp_ar() and parse_ppp_ar_result() are two
        # separate public methods (matching PPPProcessor.process_ppp()/
        # parse_position_file() being separate calls too), rather than
        # changing parse_ppp_ar_result()'s signature to require stdout be
        # passed in by the caller.
        self._last_stdout = result.stdout
        self._last_stderr = result.stderr

        return pos_file

    def parse_ppp_ar_result(self, pos_file: Path) -> Optional[Dict]:
        """
        Parse a PRIDE-PPPAR pos_* result file.

        Finds the data line after the literal "END OF HEADER" marker line
        (exact-text match, not a regex) - skipping any "*"-prefixed
        column-label line(s) in between (CONFIRMED LIVE, pos_2026272_base:
        END OF HEADER is immediately followed by a "*Name Mjd X Y Z ...
        Nobs" label line, then the actual data line) - parses its
        space-separated columns (Name Mjd X Y Z Sx Sy Sz Rxy Rxz Ryz Sig0
        Nobs), converts ECEF X/Y/Z (meters) to geodetic lat/lon/height
        (WGS84) via _ecef_to_geodetic(), and parses the wide-lane/narrow-
        lane ambiguity fix rate via _parse_fix_rate_line() (using stdout
        captured during the most recent process_ppp_ar() call on this same
        instance, if any).

        Args:
            pos_file: Path to the pos_* file produced by process_ppp_ar()

        Returns:
            Dict with 'lat' (deg), 'lon' (deg), 'height' (m), 'sig0',
            'nobs' (int), 'wl_fix_rate'/'nl_fix_rate' (floats, percent, or
            None if the fix-rate stdout line was not found - see
            _parse_fix_rate_line()), plus the raw ECEF/name/mjd fields for
            diagnostics. None if the file is missing, has no "END OF
            HEADER" marker, or the data line cannot be parsed.
        """
        if not pos_file.exists():
            logger.error(f"pos_* file not found: {pos_file}")
            return None

        logger.info(f"parse_ppp_ar_result: parsing {pos_file}")

        try:
            raw_content = pos_file.read_text(errors='replace')
        except Exception as e:
            logger.error(f"parse_ppp_ar_result: failed to read pos_* file {pos_file}: {e}")
            return None

        lines = raw_content.splitlines()

        header_idx = None
        for i, line in enumerate(lines):
            # Exact-text match on the literal marker, not a regex - per
            # Pesho's explicit "exact match on the literal text" instruction.
            if _END_OF_HEADER_MARKER in line:
                header_idx = i
                break

        if header_idx is None:
            logger.error(
                f"parse_ppp_ar_result: '{_END_OF_HEADER_MARKER}' marker not "
                f"found in {pos_file} - FULL raw content:\n{raw_content}"
            )
            return None

        # CONFIRMED LIVE (BaseStation, pos_2026272_base): immediately after
        # END OF HEADER comes a column-label line starting with "*" (e.g.
        # "*Name         Mjd               X ... Nobs"), and only THEN the
        # actual single data line - skip any "*"-prefixed line(s) (blank
        # lines are also skipped, as before) rather than treating the
        # first non-blank line as data. We've only observed exactly one
        # such label line in practice, but the loop tolerates more than
        # one without assuming a fixed count.
        data_line = None
        for line in lines[header_idx + 1:]:
            stripped = line.strip()
            if not stripped:
                continue
            if stripped.startswith('*'):
                continue
            data_line = stripped
            break

        if data_line is None:
            logger.error(
                f"parse_ppp_ar_result: no data line found after "
                f"'{_END_OF_HEADER_MARKER}' (and any '*'-prefixed column-label "
                f"lines) in {pos_file} - FULL raw content:\n{raw_content}"
            )
            return None

        fields = data_line.split()
        # Name Mjd X Y Z Sx Sy Sz Rxy Rxz Ryz Sig0 Nobs = 13 columns
        if len(fields) < 13:
            logger.error(
                f"parse_ppp_ar_result: unexpected column count in pos_* "
                f"data line (expected 13, got {len(fields)}): {data_line!r} - "
                f"FULL raw content of {pos_file}:\n{raw_content}"
            )
            return None

        try:
            name = fields[0]
            mjd = float(fields[1])
            x, y, z = float(fields[2]), float(fields[3]), float(fields[4])
            sx, sy, sz = float(fields[5]), float(fields[6]), float(fields[7])
            rxy, rxz, ryz = float(fields[8]), float(fields[9]), float(fields[10])
            sig0 = float(fields[11])
            nobs = int(float(fields[12]))
        except ValueError as e:
            logger.error(
                f"parse_ppp_ar_result: failed to parse pos_* data line "
                f"columns: {e} ({data_line!r}) - FULL raw content of "
                f"{pos_file}:\n{raw_content}"
            )
            return None

        geodetic = _ecef_to_geodetic(x, y, z)

        fix_rates = _parse_fix_rate_line(getattr(self, '_last_stdout', ''))

        result = {
            'lat': geodetic['lat'],
            'lon': geodetic['lon'],
            'height': geodetic['height'],
            'sig0': sig0,
            'nobs': nobs,
            'wl_fix_rate': fix_rates['wl_fix_rate'],
            'nl_fix_rate': fix_rates['nl_fix_rate'],
            # Diagnostics - raw fields from the pos_* data line, not
            # required by any downstream consumer yet but cheap to keep.
            'name': name,
            'mjd': mjd,
            'x': x, 'y': y, 'z': z,
            'sx': sx, 'sy': sy, 'sz': sz,
            'rxy': rxy, 'rxz': rxz, 'ryz': ryz,
        }

        logger.info(
            f"parse_ppp_ar_result: parsed fields: name={name!r} mjd={mjd} "
            f"x={x} y={y} z={z} sx={sx} sy={sy} sz={sz} "
            f"rxy={rxy} rxz={rxz} ryz={ryz} sig0={sig0} nobs={nobs} "
            f"wl_fix_rate={fix_rates['wl_fix_rate']} nl_fix_rate={fix_rates['nl_fix_rate']} "
            f"-> lat={geodetic['lat']} lon={geodetic['lon']} height={geodetic['height']}"
        )

        return result
