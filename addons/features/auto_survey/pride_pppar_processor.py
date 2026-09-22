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
pos_2020001_abmf) under work_dir - process_ppp_ar() searches both work_dir
itself and work_dir/results/ (recursively, one level) since the exact
output subdirectory layout was not pinned down to a single confirmed path
in this session; see process_ppp_ar()'s own comment for the search order.
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
import re
import shutil
import subprocess
from pathlib import Path
from typing import Dict, List, Optional

logger = logging.getLogger(__name__)

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
    Locate the pdp3 binary via PATH, matching spp_processor.py's
    find_rtklib_tool() PATH-first discovery convention. PRIDE-PPPAR's own
    install convention (~/.PRIDE_PPPAR_BIN added to .bashrc) means this
    only succeeds in a shell that has sourced .bashrc (an interactive/
    login shell) - a bare non-login subprocess environment may not see
    it, same PATH-visibility caveat that applies to any .bashrc-appended
    directory.

    Returns:
        Path to pdp3, or None if not found on PATH.
    """
    tool_path = shutil.which("pdp3")
    if tool_path:
        logger.info(f"Found pdp3 at {tool_path} (via PATH)")
        return Path(tool_path)
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
            logger.error(f"Observation file not found: {obs_file}")
            return None

        work_dir = Path(work_dir)
        work_dir.mkdir(parents=True, exist_ok=True)

        # pdp3 resolves its obs-file argument relative to cwd (confirmed
        # live) - copy obs_file into work_dir first if it isn't already
        # there, so the basename-only argument below actually resolves.
        local_obs_file = work_dir / obs_file.name
        if obs_file.resolve() != local_obs_file.resolve():
            shutil.copyfile(obs_file, local_obs_file)

        # Confirmed live CLI: `pdp3 -m S <obs-file>` (static mode). No
        # config file, no sp3/clk arguments - see module docstring.
        pdp3_args = [str(self.pdp3), "-m", "S", local_obs_file.name]

        # CRITICAL: pdp3 must run under an enlarged stack ulimit, set in
        # the SAME shell process that execs it (see module docstring) - a
        # bash -c wrapper with `ulimit -s unlimited; exec pdp3 ...`, not a
        # direct argv subprocess call and not a Python-side
        # resource.setrlimit() call.
        shell_cmd = f"ulimit -s unlimited; exec {' '.join(pdp3_args)}"

        logger.info(f"Processing PPP-AR: {local_obs_file.name} (pdp3 -m S, work_dir={work_dir})")
        logger.debug(f"Command: bash -c \"{shell_cmd}\"")

        try:
            result = subprocess.run(
                ["bash", "-c", shell_cmd],
                cwd=work_dir,
                timeout=2400,
                capture_output=True,
                text=True,
            )
        except subprocess.TimeoutExpired:
            logger.error("pdp3 timeout (>40 minutes)")
            return None
        except Exception as e:
            logger.error(f"pdp3 processing failed: {e}", exc_info=True)
            return None

        if result.returncode != 0:
            logger.error(f"pdp3 failed (exit {result.returncode}): {result.stderr}")
            return None

        # Output location was not pinned down to a single confirmed path
        # in this session - search work_dir itself first, then
        # work_dir/results/ (one level deep, covering a possible
        # work_dir/results/<doy>/ layout), in that order. First match wins.
        pos_files = list(work_dir.glob(_POS_FILE_GLOB))
        if not pos_files:
            results_dir = work_dir / "results"
            if results_dir.is_dir():
                pos_files = list(results_dir.glob(_POS_FILE_GLOB)) + \
                            list(results_dir.glob(f"*/{_POS_FILE_GLOB}"))

        if not pos_files:
            logger.error(
                f"No pos_* result file found in {work_dir} or "
                f"{work_dir}/results/ after pdp3 run"
            )
            return None

        # If multiple pos_* files exist (e.g. a stale file from a prior
        # run reusing the same work_dir), take the most recently modified
        # one - mirrors ppp_processor.py's own nav-file auto-detection
        # tie-break convention (max by mtime).
        pos_file = max(pos_files, key=lambda p: p.stat().st_mtime)

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

        Finds the data line immediately after the literal "END OF HEADER"
        marker line (exact-text match, not a regex), parses its
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

        try:
            lines = pos_file.read_text(errors='replace').splitlines()
        except Exception as e:
            logger.error(f"Failed to read pos_* file {pos_file}: {e}")
            return None

        header_idx = None
        for i, line in enumerate(lines):
            # Exact-text match on the literal marker, not a regex - per
            # Pesho's explicit "exact match on the literal text" instruction.
            if _END_OF_HEADER_MARKER in line:
                header_idx = i
                break

        if header_idx is None:
            logger.error(f"'{_END_OF_HEADER_MARKER}' marker not found in {pos_file}")
            return None

        data_line = None
        for line in lines[header_idx + 1:]:
            stripped = line.strip()
            if stripped:
                data_line = stripped
                break

        if data_line is None:
            logger.error(f"No data line found after '{_END_OF_HEADER_MARKER}' in {pos_file}")
            return None

        fields = data_line.split()
        # Name Mjd X Y Z Sx Sy Sz Rxy Rxz Ryz Sig0 Nobs = 13 columns
        if len(fields) < 13:
            logger.error(
                f"Unexpected column count in pos_* data line "
                f"(expected 13, got {len(fields)}): {data_line!r}"
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
            logger.error(f"Failed to parse pos_* data line columns: {e} ({data_line!r})")
            return None

        geodetic = _ecef_to_geodetic(x, y, z)

        fix_rates = _parse_fix_rate_line(getattr(self, '_last_stdout', ''))

        return {
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
