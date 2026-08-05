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

RTKLIB CLI ARGUMENT CONVENTION - CONFIRMED FROM RTKLIB DOCUMENTATION, NOT
INDEPENDENTLY TESTED: this dev environment cannot execute
tools/bin/RTKLIB-2.5.0/aarch64/rnx2rtkp (an ARM Linux binary; this is a
Windows dev host, the same constraint noted throughout this session's
Phase 2a/2b/2c work). rnx2rtkp takes its precise-product inputs as
ADDITIONAL TRAILING POSITIONAL ARGUMENTS after the obs/nav files (the same
pattern SPPProcessor already uses for the optional nav_file argument, just
extended) - rnx2rtkp auto-detects each extra file's type from its
extension/content (.sp3/.SP3 -> precise ephemeris, .clk/.CLK -> precise
clock, .atx/.ATX -> antenna phase center parameters). There is no
dedicated "-k" CLI flag for these on rnx2rtkp itself (that flag exists on
RTKLIB tools for loading a .conf OPTIONS file, a different mechanism this
module does not currently use, favoring explicit CLI flags to stay
consistent with SPPProcessor's existing style). Pesho should verify this
argument-ordering assumption against a real `rnx2rtkp --help`/manual page
on-station before the first live test - see _KNOWN_LIMITATIONS at the
bottom of this file.

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
"""

import logging
import subprocess
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


class PPPProcessorError(Exception):
    """Base class for all ppp_processor errors."""


class AntexNotFoundError(PPPProcessorError):
    """
    The ANTEX (.atx) file is missing at the expected install-time path.
    Raised instead of letting rnx2rtkp fail cryptically on a bad/missing
    trailing argument - this points the operator at the actual fix.
    """


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

        try:
            # Build rnx2rtkp command for PPP-static.
            # -p 8: ppp-static mode
            # -m 15: elevation mask 15 degrees (matches SPP and the stock
            #        rtkbase_ppp-static_default.conf's pos1-elmask)
            # -f 2: number of frequencies for relative mode = L1+L2
            #       (per this binary's own captured "-f freq" help text:
            #       "number of frequencies for relative mode
            #       (1:L1,2:L1+L2,3:L1+L2+L5)" - NOT an output-format
            #       selector, unlike an earlier version of this comment
            #       claimed. 2 (L1+L2) is the correct value given Phase 2a's
            #       confirmed dual-frequency RINEX data from the ZED-F9P;
            #       SPPProcessor's pre-existing -f 2 usage happens to be the
            #       same numeric value but for the SAME reason (this flag's
            #       meaning does not change between -p 0 and -p 8), not a
            #       coincidental overlap with a separate "output format"
            #       meaning that does not exist on this binary.
            # -v 0.0: validation threshold for integer ambiguity, 0.0
            #       meaning "no AR" (float-only). Confirmed directly against
            #       this repo's own installed rnx2rtkp's real "-? " help
            #       output captured on BS-Aheloy during Phase 2a Check 1:
            #       "-v thres  validation threshold for integer ambiguity
            #       (0.0:no AR) [3.0]". This replaces an earlier "-ar off"
            #       flag that does not exist anywhere in that captured help
            #       text and would have been silently rejected/ignored by
            #       this binary's actual argument parser. PPP-static's real
            #       fixed-ambiguity mode (PPP-AR) requires uncalibrated
            #       phase bias (UPD) products that ppp_downloader.py does
            #       not fetch - per Pesho's explicit instruction, defaulting
            #       to float (-v 0.0) rather than taking on that larger
            #       scope.
            # -o: output file
            cmd = [
                str(self.rnx2rtkp),
                "-p", "8",  # PPP-static mode
                "-m", "15",  # Elevation mask
                "-f", "2",  # L1+L2 frequencies
                "-v", "0.0",  # Float-only ambiguity resolution (no AR)
                "-o", str(output_file),
                str(obs_file),
            ]

            if nav_file:
                cmd.append(str(nav_file))

            cmd.append(str(sp3_file))

            if clk_file:
                cmd.append(str(clk_file))

            cmd.append(str(antex_path))

            logger.info(f"Processing PPP-static: {obs_file.name}")
            logger.info(f"  sp3={sp3_file.name}, clk={clk_file.name if clk_file else '(none - using SP3-embedded clocks)'}, atx={antex_path.name}")
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


# ---------------------------------------------------------------------------
# _KNOWN_LIMITATIONS
# ---------------------------------------------------------------------------
# 1. NOT LIVE-TESTED in this session, by explicit instruction. This dev
#    environment cannot execute tools/bin/RTKLIB-2.5.0/aarch64/rnx2rtkp
#    (Windows host, ARM Linux binary - the same constraint noted throughout
#    Phase 2a/2b/2c). Pesho should run a real process_ppp() call on
#    BS-Aheloy against a real .obs file plus the sp3/clk/atx files already
#    fetched during this session's live ppp_downloader.py testing, and
#    report the raw rnx2rtkp output, before Phase 2d wires this into
#    survey_controller.py.
# 2. Trailing-positional-argument convention for sp3/clk/atx files (no
#    dedicated CLI flags) is based on documented RTKLIB behavior, not
#    independently confirmed via `rnx2rtkp --help` on this repo's actual
#    installed binary. Verify this first during the live test above - if
#    wrong, the fix is localized to process_ppp()'s cmd list construction.
# 3. RESOLVED (was previously an open question, not just fixed): the
#    original "-ar off" flag does not exist anywhere in this repo's own
#    installed rnx2rtkp's real "-? " help output, captured verbatim on
#    BS-Aheloy during Phase 2a Check 1 - it would have been silently
#    rejected or ignored by this binary's actual argument parser, not
#    merely unverified. Float-only ambiguity resolution is now correctly
#    expressed as "-v 0.0" (validation threshold 0.0 = "no AR"), per that
#    same captured help text: "-v thres  validation threshold for integer
#    ambiguity (0.0:no AR) [3.0]". This is grounded in this repo's own
#    binary's documented CLI, not external/general RTKLIB documentation -
#    no further live verification of this specific flag is needed.
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
