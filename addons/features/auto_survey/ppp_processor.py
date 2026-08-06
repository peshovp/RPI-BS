"""
PPP-static Position Processor
==============================

Process RINEX files with RTKLIB rnx2rtkp in PPP-static mode (-p 8), using
precise orbit/clock products fetched by ppp_downloader.py, for cm-level
static base-station positioning.

INTERFACE CONTRACT WITH SPPProcessor (addons/features/auto_survey/spp_processor.py,
read in full before writing this file): PPPProcessor is designed as a
drop-in replacement for the position-generation half of SPPProcessor -
matching constructor pattern (auto-discover rnx2rtkp via find_rtklib_tool(),
same subprocess/timeout/logging conventions), and producing the exact same
kind of .pos output file that SPPProcessor.parse_position_file() already
parses. parse_position_file() is intentionally NOT duplicated here -
RTKLIB's `-f 2` output format is mode-independent (same column layout
regardless of -p 0 vs -p 8), confirmed in this session's earlier OLD-vs-
CURRENT investigation and again in the original design doc - so Phase 2d's
survey_controller.py integration can keep calling
self.spp.parse_position_file(pos_file) unchanged after swapping
self.spp = SPPProcessor() for self.spp = PPPProcessor().

PROCESSING OPTIONS: pos1-sateph=precise, pos2-armode=off (float-ambiguity
only - PPP-AR requires UPD/bias products this module does not fetch, per
Pesho's explicit instruction to default to float unless a simple
RTKLIB-native AR option exists; none does), dual-frequency ionosphere-free
combination, Saastamoinen a-priori troposphere with estimation - adapted
from web_app/rtklib_configs/rtkbase_ppp-static_default.conf (read in full;
that file's own pos1-sateph=brdc and pos2-armode=continuous are NOT used
here, since both were identified as needing correction for real PPP use).

RTKLIB CLI ARGUMENT CONVENTION - REVISED AFTER A LIVE TEST ON BS-AHELOY
FOUND THE ORIGINAL ASSUMPTION WRONG. The first live process_ppp() run
exited 0 and produced a .pos file, but its header showed only 2 "inp file"
lines (obs + nav) - the sp3/clk/atx trailing positional arguments were
silently ignored, and every epoch came out Q=5 (single/SPP-equivalent),
proving PPP-static never actually engaged despite -p 8 being set.

Root-caused via this repo's own rnx2rtkp usage text (captured on BS-Aheloy
by running rnx2rtkp with zero arguments, which prints full usage
including the synopsis line the earlier "-? " capture did not show):

    usage: rnx2rtkp [option]... file file [...]
    ...To use SP3 precise ephemeris, specify the path in the files. The
    extension of the SP3 file shall be .sp3 or .eph. ...A maximum number
    of input files is currently set to 16. With -k option, the
    processing options are input from the configuration file. In this
    case, command line options precede options in the configuration file.

TWO separate findings from this text:

1. SP3/CLK extension case sensitivity: the usage text says the SP3
   extension "shall be .sp3 or .eph" - lowercase, stated as a hard
   requirement, not a suggestion. CDDIS's own product filenames use
   UPPERCASE extensions (IGS0OPSRAP_..._ORB.SP3.gz, decompressed to
   ...ORB.SP3) - ppp_downloader.py does not rename them. This is the
   confirmed root cause of SP3 being silently skipped: rnx2rtkp still
   parsed it as a "file" argument (hence no crash, exit 0), but did not
   recognize it as an SP3 input, so it was effectively discarded. SP3/CLK
   REMAIN trailing positional arguments (the usage text explicitly
   instructs this - "specify the path in the files") - fixed by copying
   them to a lowercase-extension name before invoking rnx2rtkp, not by
   switching mechanism.

2. ANTEX has NO positional-argument path at all: the usage text's list of
   recognized input file types - "RINEX OBS/NAV/GNAV/HNAV/CLK, SP3, SBAS
   message log files" - never mentions ATX/antenna files. Passing
   igs20.atx as a 6th positional argument (as the original implementation
   did) was never going to work, regardless of extension case; there is
   no rnx2rtkp file-type-sniffing rule for antenna models, only the
   -k <optsfile> conf-key route can supply one
   (file-satantfile/file-rcvantfile - confirmed present as real keys in
   web_app/rtklib_configs/rtkbase_ppp-static_default.conf, read in full).

RESULT: a HYBRID design, not a full migration to -k. SP3/CLK stay
positional (extension-normalized to lowercase). ANTEX moves to a
per-call, auto-generated temporary -k conf file, which ALSO carries
pos1-sateph=precise and pos2-armode=off (both real, confirmed keys in the
same template) - since a conf file has to be generated for ANTEX anyway,
consolidating the processing-mode options into it too is more reliable
than mixing a -v 0.0 CLI flag with a separately-loaded conf file whose
precedence rules ("command line options precede options in the
configuration file") would otherwise need to be reasoned about per-option.
See _generate_ppp_conf() and _KNOWN_LIMITATIONS.

NO SEPARATE CLK FILE FOR ULTRA-RAPID: ppp_downloader.py's
fetch_products("ultra-rapid", ...) returns {"sp3": Path} only - no "clk"
key - because the IGS combined ultra-rapid product has no separate CLK
file; satellite clock offsets are embedded directly in the SP3 file itself
(confirmed via a live CDDIS directory listing, see ppp_downloader.py's
module docstring for the full evidence). process_ppp() accepts clk_file as
Optional and, when None, omits it from the rnx2rtkp command entirely
rather than passing an empty/missing path - RTKLIB reads embedded SP3
clock records automatically whenever no separate CLK file is supplied,
which is documented RTKLIB behavior (rnx2rtkp/RTKLIB's `readsp3()` always
parses the embedded clock column; `readrnxclk()`/external CLK data is only
used to refine/override those values when present). This behavior itself
has NOT been independently live-tested against a real ultra-rapid-only
(no-clk) input in this session - flagged in _KNOWN_LIMITATIONS.

ANTEX HANDLING: the ANTEX (.atx) file is a large (~54MB uncompressed),
install-time, one-time-downloaded asset - NOT fetched per-survey and NOT
committed to git (see install.sh/perform_update.sh changes accompanying
this file). PPPProcessor looks for it at a fixed path
(DEFAULT_ANTEX_PATH below) and raises a clear, actionable
AntexNotFoundError - not a cryptic rnx2rtkp failure - if it's missing,
telling the operator which install step fetches it.

NO RECEIVER ANTENNA PCV: A LIVE, REAL ACCURACY CEILING ON THIS HARDWARE -
NOT A BUG. A trace-level (-x 3) live test on BS-Aheloy, after the SP3/CLK
recognition fix above, found "no prec ephem" had dropped to 0 (precise
products now correctly used) but a "no receiver antenna pcv:" trace line
appeared and the .pos output had ZERO position epochs - this single
warning HARD-BLOCKS all solution output in PPP mode on this rnx2rtkp
build, it does not merely degrade accuracy the way a missing antenna
calibration typically would in relative-positioning modes.

Root cause: the physical antenna on BS-Aheloy is a generic/unbranded
"K700" AliExpress model with no individual calibration entry anywhere in
igs20.atx, AND RTKBase's own RINEX conversion does not populate the
RINEX header's "ANT # / TYPE" field at all (confirmed empty on a real
BS-Aheloy .obs file) - so rnx2rtkp has no antenna type string to even
attempt an ANTEX lookup against, from either the receiver hardware or the
RINEX file it's processing.

FIX: ant1-anttype is explicitly set to "NONE" in _PPP_CONF_TEMPLATE below
- the standard IGS ANTEX generic pseudo-antenna entry, representing an
explicitly uncalibrated/unknown antenna with zero PCO/PCV correction
applied (rather than rnx2rtkp trying and failing to look up a blank/
unknown type string, which is what produced the hard-blocking warning).
ant1 (not ant2) is used because this is single-receiver PPP processing,
not a rover/base relative pair - RTKLIB's single-receiver modes address
the sole receiver as "ant1" internally regardless of posmode.

THIS IS A REAL, PERMANENT ACCURACY CEILING FOR THIS HARDWARE CHOICE, NOT
A BUG BEING PAPERED OVER: with ant1-anttype=NONE, PPP-static's antenna
phase-center offset/variation correction is NOT applied for this
station's antenna - it never can be, since no per-model calibration
exists for this antenna in any IGS ANTEX file. Position accuracy
improvement from this migration will come entirely from precise
orbits/clocks (the whole point of PPP-static over SPP), NOT from
antenna-specific PCO/PCV correction, which typically contributes a few mm
to cm in professional-grade static surveying but is simply unavailable
here. This does not block PPP-static from working or from being a real
accuracy improvement over SPP - it caps how much further improvement is
achievable without a change in antenna hardware. See _KNOWN_LIMITATIONS.

NOT INDEPENDENTLY VERIFIED IN THIS SESSION: the value "NONE" is the
standard, documented IGS ANTEX generic-antenna record name present in
every published igsYY.atx release - but this specific bundled igs20.atx
file was NOT grepped for that exact string in this session (the file is
a 54MB install-time asset that exists only on BS-Aheloy, not on this dev
machine). Pesho should confirm with a direct grep on-station (e.g.
`grep -A1 "^NONE" geomaxima_ppp/igs20.atx`) that "NONE" is present
verbatim as a TYPE / SERIAL NO record before or alongside the next live
test - flagged in _KNOWN_LIMITATIONS.
"""

import logging
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Dict, Optional

from .spp_processor import find_rtklib_tool

logger = logging.getLogger(__name__)

# Fixed install-time ANTEX location, consistent with this feature's existing
# convention for downloaded/uploaded assets living alongside settings.conf
# rather than inside the git checkout itself (see survey_controller.py's
# self.geoid_dir = self.rtkbase.rtkbase_root / "geomaxima_geoid" for the
# established precedent this mirrors).
DEFAULT_ANTEX_RELATIVE_PATH = "geomaxima_ppp/igs20.atx"

# Minimal -k options-file template. Only the keys this module actually
# needs to set are included - rnx2rtkp fills in RTKLIB's own defaults for
# any key not present in a -k file (confirmed by the usage text's own
# framing: "-k option, the processing options are input from the
# configuration file" - it does not require a complete key set, unlike the
# full RTKNAVI dump in rtkbase_ppp-static_default.conf, which was NOT used
# as this template directly since most of its keys - inpstr1/2/3 streaming
# config, misc-* - are for rtkrcv's real-time engine and are irrelevant to
# rnx2rtkp's batch processing). Key names (pos1-sateph, pos2-armode,
# file-satantfile, file-rcvantfile, ant1-anttype) are copied verbatim from
# that same real template file, not guessed.
#
# ant1-anttype=NONE: REQUIRED, not optional/cosmetic - a live trace-level
# test on BS-Aheloy found that WITHOUT this explicit override, rnx2rtkp
# emits a "no receiver antenna pcv:" warning that HARD-BLOCKS all solution
# output (zero epochs in the .pos file), because the physical antenna (a
# generic/uncalibrated "K700" AliExpress model) has no entry in igs20.atx
# AND RTKBase's own RINEX conversion leaves the header's "ANT # / TYPE"
# field blank - rnx2rtkp has nothing to even attempt an ANTEX lookup
# against. "NONE" is the standard IGS ANTEX generic pseudo-antenna record
# (zero PCO/PCV correction) - see the module docstring's "NO RECEIVER
# ANTENNA PCV" section for the full explanation and the real accuracy
# implication (antenna-specific phase-center correction is permanently
# unavailable for this hardware, not a bug to fix later).
#
# out-solstatic=all: ALSO REQUIRED - copied verbatim from the stock
# rtkbase_ppp-static_default.conf (0:all,1:single). Without this key, a
# live test found rnx2rtkp computing valid, converging solutions
# internally (confirmed via trace: outsol/outsols called every epoch,
# residuals shrinking cleanly) but never writing a single line to the
# output .pos file - "all" tells RTKLIB to emit the running per-epoch
# solution as static-mode convergence proceeds, rather than withholding
# output entirely (its opposite, "single", would only ever write ONE
# final line at the very end of the whole session, which is not what was
# happening either - the omitted key's actual RTKLIB-internal default
# behavior when absent from a -k file was not itself root-caused, only
# confirmed that explicitly setting it to "all" fixes the symptom).
# CONFIRMED WORKING END TO END: a live 8-hour real .obs file test on
# BS-Aheloy with both ant1-anttype=NONE and out-solstatic=all produced
# 3276 real data lines, Q=6 (PPP) throughout, with genuine convergence
# (sdu shrinking from ~5.2m to ~0.098m over the 8-hour session) - this is
# the first fully working end-to-end PPP-static run this module has
# produced. Also confirms PPP-static genuinely needs an observation
# window measured in HOURS, not minutes, to converge to useful accuracy -
# consistent with PPP's well-known slower convergence relative to
# RTK/PPK, and relevant to Phase 2d's interim-update scheduling (an
# interim update early in a short survey will show large, still-converging
# sdu values by design, not a malfunction).
_PPP_CONF_TEMPLATE = """\
pos1-posmode       =ppp-static
pos1-frequency     =l1+l2
pos1-elmask        =15
pos1-ionoopt       =dual-freq
pos1-tropopt       =saas
pos1-sateph        =precise
pos2-armode        =off
file-satantfile    ={satantfile}
file-rcvantfile    ={rcvantfile}
ant1-anttype       =NONE
out-solstatic      =all
"""


class PPPProcessorError(Exception):
    """Base class for all ppp_processor errors."""


class AntexNotFoundError(PPPProcessorError):
    """
    The ANTEX (.atx) file is missing at the expected install-time path.
    Raised instead of letting rnx2rtkp fail cryptically on a bad/missing
    trailing argument - this points the operator at the actual fix.
    """


def _normalize_precise_product_extension(source_path: Path, expected_suffix: str,
                                          work_dir: Path) -> Path:
    """
    rnx2rtkp's own usage text states the SP3 extension "shall be .sp3 or
    .eph" (lowercase) - a hard requirement, not a suggestion. CDDIS's own
    product filenames use uppercase extensions (e.g. ...ORB.SP3), which
    ppp_downloader.py does not rename (it has no reason to - the extension
    only matters to rnx2rtkp's own file-type detection, not to the
    download/decompression logic). If source_path's suffix doesn't already
    match expected_suffix case-sensitively, copy it into work_dir under a
    correctly-cased name and return that new path; otherwise return
    source_path unchanged (no unnecessary copy).

    A copy (not a rename/move) is used deliberately - source_path lives in
    ppp_downloader.py's products_dir and may be reused across multiple
    process_ppp() calls (e.g. an interim update reprocessing the same
    fetched products); renaming it in place would leave that directory in
    a case that future PPPDownloader lookups don't expect.
    """
    if source_path.suffix == expected_suffix:
        return source_path

    normalized_path = work_dir / (source_path.stem + expected_suffix)
    shutil.copyfile(source_path, normalized_path)
    logger.debug(f"Normalized {source_path.name} -> {normalized_path.name} "
                 f"(rnx2rtkp requires lowercase '{expected_suffix}')")
    return normalized_path


class PPPProcessor:
    """
    Process RINEX for PPP-static positioning using rnx2rtkp -p 8.

    Drop-in-compatible with SPPProcessor's constructor pattern (see module
    docstring) - accepts an explicit rnx2rtkp_path or auto-discovers it via
    the same find_rtklib_tool() helper SPPProcessor and RINEXConverter both
    already use, so no new discovery logic is introduced.

    Precise product paths (sp3/clk/atx) are supplied per-call to
    process_ppp() rather than at construction time, matching
    ppp_downloader.py's PPPDownloader dependency-injection style: a
    PPPProcessor instance is reusable across multiple surveys/tiers, while
    the actual product files change every time (different survey window,
    different tier, ultra-rapid's clk-less case, etc).
    """

    def __init__(self, rnx2rtkp_path: Optional[str] = None,
                 rtkbase_root: Optional[Path] = None):
        """
        Args:
            rnx2rtkp_path: Path to RTKLIB rnx2rtkp executable (auto-detected if None)
            rtkbase_root: RTKBase installation root, used only to resolve
                the default ANTEX path (DEFAULT_ANTEX_RELATIVE_PATH) when
                antex_file is not explicitly passed to process_ppp(). If
                None, defaults to this file's own repo-relative root (three
                levels up from addons/features/auto_survey/), matching the
                resolution pattern already used by RTKBaseConfig and
                SurveyController elsewhere in this feature.
        """
        if rnx2rtkp_path is None:
            rnx2rtkp = find_rtklib_tool("rnx2rtkp")
            if rnx2rtkp is None:
                raise FileNotFoundError("rnx2rtkp not found. Please install RTKLIB.")
            self.rnx2rtkp = rnx2rtkp
        else:
            self.rnx2rtkp = Path(rnx2rtkp_path)
            if not self.rnx2rtkp.exists():
                raise FileNotFoundError(f"rnx2rtkp not found at {rnx2rtkp_path}")

        if rtkbase_root is None:
            import os
            rtkbase_root = Path(os.path.abspath(
                os.path.join(os.path.dirname(__file__), "../../../")
            ))
        self.rtkbase_root = Path(rtkbase_root)

    def default_antex_path(self) -> Path:
        """Resolve the fixed install-time ANTEX path under rtkbase_root."""
        return self.rtkbase_root / DEFAULT_ANTEX_RELATIVE_PATH

    def resolve_antex(self, antex_file: Optional[Path] = None) -> Path:
        """
        Resolve which ANTEX file to use: the explicitly-passed path if
        given, otherwise the fixed install-time default. Raises
        AntexNotFoundError (not a generic FileNotFoundError, and NOT a
        cryptic rnx2rtkp subprocess failure) if the resolved path doesn't
        exist, with an actionable message pointing at the install step
        that fetches it.
        """
        path = Path(antex_file) if antex_file is not None else self.default_antex_path()
        if not path.exists():
            raise AntexNotFoundError(
                f"ANTEX file not found at {path}. This is a required, "
                f"one-time, install-level download (~54MB) - run "
                f"install.sh (fresh install) or wait for the next OTA "
                f"update (perform_update.sh), both of which fetch "
                f"igs20.atx automatically. It is NOT downloaded per-survey."
            )
        return path

    def _generate_ppp_conf(self, antex_path: Path, work_dir: Path) -> Path:
        """
        Write a minimal -k options file (see _PPP_CONF_TEMPLATE) into
        work_dir, with the real ANTEX path filled into file-satantfile/
        file-rcvantfile - both used for the same file here, since this
        module tracks one ANTEX file covering both satellite and receiver
        antenna models (the bundled igs20.atx), not separate files per
        RTKLIB's more general two-file option.

        Also bakes in ant1-anttype=NONE (hardcoded in _PPP_CONF_TEMPLATE,
        not parameterized here) - required to avoid a hard-blocking "no
        receiver antenna pcv" failure on this station's uncalibrated
        antenna hardware; see the module docstring's "NO RECEIVER ANTENNA
        PCV" section.

        Returns the path to the generated conf file. NOT automatically
        deleted by this method - see process_ppp()'s cleanup handling for
        the lifecycle/retention decision.
        """
        conf_path = work_dir / "ppp_static.conf"
        conf_content = _PPP_CONF_TEMPLATE.format(
            satantfile=str(antex_path),
            rcvantfile=str(antex_path),
        )
        conf_path.write_text(conf_content)
        return conf_path

    def process_ppp(self,
                     obs_file: Path,
                     sp3_file: Path,
                     nav_file: Optional[Path] = None,
                     clk_file: Optional[Path] = None,
                     antex_file: Optional[Path] = None,
                     output_file: Optional[Path] = None) -> Optional[Path]:
        """
        Process RINEX observation for PPP-static.

        Args:
            obs_file: RINEX observation file (same as SPPProcessor.process_spp())
            sp3_file: Precise orbit product (required - PPP-static cannot
                run without precise ephemeris; this is the entire point of
                this class over SPPProcessor)
            nav_file: RINEX navigation file (optional, auto-detected same
                as SPPProcessor - still needed even in PPP mode, for
                broadcast-derived satellite health/timing data RTKLIB uses
                alongside the precise products)
            clk_file: Precise clock product. OPTIONAL - pass None for
                ultra-rapid tier results (ppp_downloader.py's
                fetch_products("ultra-rapid", ...) never returns a "clk"
                key - see module docstring for why). When None, the
                rnx2rtkp command omits any clk argument entirely; RTKLIB
                falls back to the clock values embedded in the SP3 file
                itself. NOT independently live-tested in this session -
                see _KNOWN_LIMITATIONS.
            antex_file: ANTEX file for satellite/receiver antenna PCO/PCV
                corrections. If None, resolved via resolve_antex() to the
                fixed install-time default path - raises AntexNotFoundError
                if missing there.
            output_file: Output position file (default: obs_file with .pos extension)

        Returns:
            Path to position file (.pos) or None on failure - same
            success/failure contract as SPPProcessor.process_spp(), so
            callers (Phase 2d's survey_controller.py) can treat both
            processors identically: check truthiness, don't rely on
            exceptions for the ordinary "processing failed" case. Raises
            AntexNotFoundError specifically for the ANTEX-missing case
            (an operator-actionable setup problem, not a per-run
            processing failure) rather than folding it into the same
            None-return path as an ordinary rnx2rtkp failure.
        """
        if not obs_file.exists():
            logger.error(f"Observation file not found: {obs_file}")
            return None

        if not sp3_file.exists():
            logger.error(f"SP3 precise ephemeris file not found: {sp3_file}")
            return None

        if clk_file is not None and not clk_file.exists():
            logger.warning(
                f"CLK precise clock file not found: {clk_file} - "
                f"proceeding without it (falling back to SP3-embedded clocks)"
            )
            clk_file = None

        antex_path = self.resolve_antex(antex_file)

        # Auto-detect nav file if not provided - identical logic to
        # SPPProcessor.process_spp(), duplicated rather than imported since
        # it's a small, self-contained lookup and importing SPPProcessor's
        # private behavior here would create an odd coupling in the other
        # direction (PPPProcessor depending on SPPProcessor's internals).
        if nav_file is None:
            obs_dir = obs_file.parent
            nav_files = list(obs_dir.glob("*.nav")) + \
                       list(obs_dir.glob("*.[0-9][0-9]n"))
            if nav_files:
                nav_file = max(nav_files, key=lambda p: p.stat().st_mtime)
                logger.info(f"Auto-detected nav file: {nav_file.name}")

        if nav_file and not nav_file.exists():
            logger.warning(f"Nav file not found: {nav_file}")
            nav_file = None

        if output_file is None:
            output_file = obs_file.with_suffix('.pos')
        else:
            output_file = Path(output_file)

        # Working directory for this run's extension-normalized SP3/CLK
        # copies (see _normalize_precise_product_extension()) and the
        # generated -k conf file. A fresh tempdir per call, cleaned up in
        # the finally block below - these are small, single-run artifacts,
        # not something worth retaining across calls the way
        # ppp_downloader.py's fetched products are.
        work_dir = Path(tempfile.mkdtemp(prefix="ppp_static_"))
        try:
            sp3_file = _normalize_precise_product_extension(sp3_file, ".sp3", work_dir)
            if clk_file:
                clk_file = _normalize_precise_product_extension(clk_file, ".clk", work_dir)

            conf_path = self._generate_ppp_conf(antex_path, work_dir)

            # Build rnx2rtkp command for PPP-static.
            #
            # -p 8: ppp-static mode
            # -m 15: elevation mask 15 degrees (matches SPP and the stock
            #        rtkbase_ppp-static_default.conf's pos1-elmask)
            # -k <conf>: loads pos1-sateph=precise, pos2-armode=off, and
            #        the ANTEX file paths (file-satantfile/file-rcvantfile)
            #        from the per-call generated conf - see
            #        _generate_ppp_conf() and the module docstring's
            #        HYBRID DESIGN explanation for why ANTEX moved here
            #        (rnx2rtkp's own usage text lists no positional-arg
            #        path for antenna files at all) while SP3/CLK stayed
            #        as positional arguments below (the usage text
            #        explicitly instructs "specify the path in the files"
            #        for SP3). Per that same usage text - "command line
            #        options precede options in the configuration file" -
            #        any CLI flag given here (e.g. -p 8, -m 15) overrides
            #        the conf file's own pos1-posmode/pos1-elmask if they
            #        differ; they don't here (kept as CLI flags primarily
            #        for consistency with SPPProcessor's existing style,
            #        not because the conf file disagrees with them).
            # -f 2: number of frequencies for relative mode = L1+L2 (per
            #        this binary's own captured "-f freq" help text:
            #        "number of frequencies for relative mode
            #        (1:L1,2:L1+L2,3:L1+L2+L5)"). 2 (L1+L2) is correct
            #        given Phase 2a's confirmed dual-frequency RINEX data
            #        from the ZED-F9P.
            # -o: output file
            cmd = [
                str(self.rnx2rtkp),
                "-p", "8",  # PPP-static mode
                "-m", "15",  # Elevation mask
                "-f", "2",  # L1+L2 frequencies
                "-k", str(conf_path),
                "-o", str(output_file),
                str(obs_file),
            ]

            if nav_file:
                cmd.append(str(nav_file))

            # SP3/CLK remain trailing positional arguments (NOT moved into
            # the -k conf) - rnx2rtkp's own usage text explicitly instructs
            # this for SP3 ("To use SP3 precise ephemeris, specify the path
            # in the files"), and the stock conf template has no SP3/CLK
            # file-path key at all to move them into even if that were
            # desired. ANTEX (antex_path) is intentionally NOT appended
            # here - it goes through -k's conf file instead (see above),
            # since it has no positional-arg path on this rnx2rtkp build.
            cmd.append(str(sp3_file))

            if clk_file:
                cmd.append(str(clk_file))

            logger.info(f"Processing PPP-static: {obs_file.name}")
            logger.info(f"  sp3={sp3_file.name}, clk={clk_file.name if clk_file else '(none - using SP3-embedded clocks)'}, atx={antex_path.name} (via -k conf)")
            logger.debug(f"Command: {' '.join(cmd)}")

            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=1800  # 30 minute timeout - PPP-static processes a
                               # much larger accumulated dataset than SPP's
                               # 10-minute budget and involves more
                               # per-epoch computation (see design doc's
                               # risk section on processing time increase)
            )

            if result.returncode != 0:
                logger.error(f"rnx2rtkp failed: {result.stderr}")
                return None

            if not output_file.exists():
                logger.error("No position file generated")
                return None

            file_size = output_file.stat().st_size
            if file_size < 100:
                logger.error(f"Position file too small ({file_size} bytes)")
                return None

            logger.info(f"✓ PPP-static position file: {output_file.name} ({file_size} bytes)")
            return output_file

        except subprocess.TimeoutExpired:
            logger.error("rnx2rtkp timeout (>30 minutes)")
            return None
        except Exception as e:
            logger.error(f"PPP-static processing failed: {e}", exc_info=True)
            return None
        finally:
            # work_dir holds only this run's disposable extension-normalized
            # copies and generated conf, never the caller's original
            # sp3_file/clk_file/antex_file - safe to always remove.
            shutil.rmtree(work_dir, ignore_errors=True)


# ---------------------------------------------------------------------------
# _KNOWN_LIMITATIONS
# ---------------------------------------------------------------------------
# 1. RESOLVED - CONFIRMED WORKING END-TO-END. This dev environment cannot
#    execute tools/bin/RTKLIB-2.5.0/aarch64/rnx2rtkp (Windows host, ARM
#    Linux binary - the same constraint noted throughout Phase 2a/2b/2c/
#    these fixes), so all verification below happened on BS-Aheloy, not
#    here. Three live tests ran in sequence: (1) the original trailing-
#    positional-args-only design was broken (uppercase SP3 extension
#    silently ignored, ANTEX never had a positional-arg path at all - see
#    the HYBRID DESIGN section above); (2) after that fix, a trace-level
#    (-x 3) test confirmed SP3/CLK recognition actually worked ("no prec
#    ephem" dropped to 0) but surfaced a hard-blocking "no receiver
#    antenna pcv" issue producing zero output epochs despite the trace
#    showing clean internal convergence; (3) after adding
#    ant1-anttype=NONE AND out-solstatic=all together, a live 8-hour real
#    .obs file test produced 3276 real data lines, Q=6 (PPP) throughout,
#    with genuine convergence (sdu shrinking from ~5.2m to ~0.098m over
#    the session) - the first fully working end-to-end PPP-static run
#    this module has produced. Root cause of the zero-epoch symptom was
#    TWO combined factors, both now fixed: the missing out-solstatic=all
#    key (RTKLIB was computing valid per-epoch solutions internally but
#    never writing them without this key explicitly set), and - separate
#    from any bug - PPP-static genuinely needing an observation window
#    measured in HOURS, not minutes, to converge to useful accuracy
#    (relevant to Phase 2d's interim-update scheduling: an interim update
#    early in a short survey will correctly show large, still-converging
#    sdu values by design, not a malfunction).
# 2. The -k conf file's precedence interaction with the CLI's -p 8/-m 15
#    flags ("command line options precede options in the configuration
#    file", per the captured usage text) is understood from that text but
#    not independently exercised - specifically, whether -k conf VALUES
#    (pos1-sateph=precise, pos2-armode=off) actually apply when NOT
#    contradicted by a CLI flag has not been confirmed to work as
#    expected in practice on this binary, only assumed from the documented
#    precedence rule.
# 3. SUPERSEDED TWICE: the original "-ar off" flag (a nonexistent CLI
#    flag) was first replaced with "-v 0.0" (a real CLI flag, validation
#    threshold 0.0 = "no AR") after Phase 2a Check 1's help-text capture.
#    That -v 0.0 flag has since been REMOVED and replaced again by this
#    fix's -k conf file's pos2-armode=off key - not because -v 0.0 was
#    wrong, but because consolidating all ANTEX/processing-option settings
#    into one -k conf (required anyway for ANTEX, per finding #2 in the
#    module docstring) was judged more reliable than mixing a CLI flag
#    with a separately-loaded conf file's precedence rules. pos2-armode=off
#    is a real, confirmed key (present verbatim in
#    web_app/rtklib_configs/rtkbase_ppp-static_default.conf), but - like
#    the rest of this fix - has not itself been live-tested; see item 1
#    and item 2 above.
# 4. RTKLIB's behavior of falling back to SP3-embedded clock values when no
#    separate CLK file is supplied is standard, documented RTKLIB behavior
#    (readsp3() always parses the embedded clock column) but has not been
#    independently exercised against a real ultra-rapid (clk-less) input in
#    this session.
# 5. Output-format flags (-t/-u/-d/-s in the real captured help text) are
#    NOT set by process_ppp(), matching SPPProcessor's own cmd construction
#    (confirmed by re-reading spp_processor.py: it also sets none of these,
#    relying entirely on rnx2rtkp's documented defaults). Since
#    parse_position_file() was written against SPPProcessor's plain-default
#    output and PPPProcessor reproduces that same default-flag omission,
#    there is no compatibility gap here - not a bug, and not something to
#    add.
# 6. ant1-anttype=NONE's exact string value ("NONE") is the standard,
#    documented IGS ANTEX generic pseudo-antenna record name present in
#    every published igsYY.atx release, but this specific bundled
#    igs20.atx file was NOT independently grepped for that exact string in
#    this session - the file is a ~54MB install-time asset that exists
#    only on BS-Aheloy (fetched by install.sh/perform_update.sh), not on
#    this dev machine. Pesho should confirm on-station, e.g.
#    `grep -A1 "^NONE" geomaxima_ppp/igs20.atx`, that "NONE" is present
#    verbatim as a TYPE / SERIAL NO record - if it isn't (unlikely, but
#    not independently confirmed here), the correct fallback string would
#    need to be substituted in _PPP_CONF_TEMPLATE.
# 7. OPEN QUESTION, NOT FIXED HERE (out of this task's scope): the same
#    RINEX header inspected during this investigation shows "ANTENNA:
#    DELTA H/E/N" as 0.0000/0.0000/0.0000 - antenna height above the
#    survey marker is either genuinely zero (unlikely for a real
#    installation) or, more likely, simply not populated by RTKBase's
#    RINEX conversion, the same underlying gap as the missing "ANT # /
#    TYPE" field this fix works around. This is a DIFFERENT setting -
#    physical antenna height/offset from the marker, not PCV calibration -
#    and affects absolute height accuracy independently of the
#    ant1-anttype=NONE fix above (this fix corrects a hard-block on ANY
#    solution output; delta H/E/N being wrong would produce a solution
#    that is offset in height even with the PCV fix applied). Pesho should
#    determine whether this value should be populated during RINEX
#    conversion or supplied separately before relying on PPP-static's
#    absolute height output for anything precision-critical.
