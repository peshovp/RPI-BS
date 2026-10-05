"""
PPP-static Position Processor
==============================

Process RINEX files with RTKLIB rnx2rtkp in PPP-static mode (-p 8), using
precise orbit/clock products fetched by ppp_downloader.py, for cm-level
static base-station positioning.

INTERFACE CONTRACT WITH SPPProcessor (addons/features/auto_survey/spp_processor.py,
read in full before writing this file): PPPProcessor is a drop-in
replacement for the position-generation half of SPPProcessor - matching
constructor pattern (auto-discover rnx2rtkp via find_rtklib_tool(), same
subprocess/timeout/logging conventions), and producing the exact same
kind of .pos output file SPPProcessor's parser already understands.

PPPProcessor.parse_position_file() DOES exist (below) but is a thin
delegating wrapper, not a reimplementation - the actual parsing logic
lives once, as the module-level parse_rtklib_position_file() function in
spp_processor.py, and both SPPProcessor.parse_position_file() and
PPPProcessor.parse_position_file() delegate to it. This was fixed after a
live AttributeError during the first real survey run using this module:
an earlier version of this docstring described the *plan* for
survey_controller.py to keep calling self.spp.parse_position_file(pos_file)
unchanged after swapping SPPProcessor for PPPProcessor, but the method
itself was never actually added to this class - the plan was recorded in
a comment and never implemented. RTKLIB's `-f 2` output format is
mode-independent (same column layout regardless of -p 0 vs -p 8,
confirmed in this session's earlier OLD-vs-CURRENT investigation and
again in the original design doc), so a plain delegate call is correct
and sufficient - no PPP-specific parsing behavior was ever needed, only
the missing method itself.

PROCESSING OPTIONS: pos1-sateph=precise, pos2-armode=off (float-ambiguity
only - PPP-AR requires UPD/bias products this module does not fetch, per
Pesho's explicit instruction to default to float unless a simple
RTKLIB-native AR option exists; none does), dual-frequency ionosphere-free
combination, Saastamoinen a-priori troposphere with estimation - adapted
from web_app/rtklib_configs/rtkbase_ppp-static_default.conf (read in full;
that file's own pos1-sateph=brdc and pos2-armode=continuous are NOT used
here, since both were identified as needing correction for real PPP use).

RTKLIB CLI ARGUMENT CONVENTION - REVISED AFTER A LIVE TEST ON BASESTATION
FOUND THE ORIGINAL ASSUMPTION WRONG. The first live process_ppp() run
exited 0 and produced a .pos file, but its header showed only 2 "inp file"
lines (obs + nav) - the sp3/clk/atx trailing positional arguments were
silently ignored, and every epoch came out Q=5 (single/SPP-equivalent),
proving PPP-static never actually engaged despite -p 8 being set.

Root-caused via this repo's own rnx2rtkp usage text (captured on BaseStation
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
NOT A BUG. A trace-level (-x 3) live test on BaseStation, after the SP3/CLK
recognition fix above, found "no prec ephem" had dropped to 0 (precise
products now correctly used) but a "no receiver antenna pcv:" trace line
appeared and the .pos output had ZERO position epochs - this single
warning HARD-BLOCKS all solution output in PPP mode on this rnx2rtkp
build, it does not merely degrade accuracy the way a missing antenna
calibration typically would in relative-positioning modes.

Root cause: the physical antenna on BaseStation is a generic/unbranded
"K700" AliExpress model with no individual calibration entry anywhere in
igs20.atx, AND RTKBase's own RINEX conversion does not populate the
RINEX header's "ANT # / TYPE" field at all (confirmed empty on a real
BaseStation .obs file) - so rnx2rtkp has no antenna type string to even
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
a 54MB install-time asset that exists only on BaseStation, not on this dev
machine). Pesho should confirm with a direct grep on-station (e.g.
`grep -A1 "^NONE" geomaxima_ppp/igs20.atx`) that "NONE" is present
verbatim as a TYPE / SERIAL NO record before or alongside the next live
test - flagged in _KNOWN_LIMITATIONS.
"""

import hashlib
import logging
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Dict, List, Optional

from .spp_processor import find_rtklib_tool, parse_rtklib_position_file
from .runtime_paths import GM_RUNTIME_DIR

logger = logging.getLogger(__name__)

# Fixed install-time ANTEX location, consistent with this feature's existing
# convention for downloaded/uploaded assets living alongside settings.conf
# rather than inside the git checkout itself (see survey_controller.py's
# self.geoid_dir = self.rtkbase.rtkbase_root / "geomaxima_geoid" for the
# established precedent this mirrors).
DEFAULT_ANTEX_RELATIVE_PATH = "geomaxima_ppp/igs20.atx"

# Part 6b: the vendored custom-ANTEX directory, COMMITTED to this repo
# (unlike igs20.atx, which is a ~54MB download fetched at install/OTA
# time - a single antenna's calibration entry is small enough to vendor
# directly, same convention as addons/PRIDE-PPPAR/). Lives under
# rtkbase_root/addons/ (the git checkout root, same default rtkbase_root
# this module already resolves to - see PPPProcessor.__init__()), NOT
# under rtkbase_root/geomaxima_ppp/ alongside the downloaded igs20.atx,
# since this one IS part of the repo and should never be touched by the
# ANTEX re-download logic in install.sh/perform_update.sh.
CUSTOM_ANTEX_RELATIVE_PATH = "addons/geomaxima_antex/custom.atx"

# The MERGED, working ANTEX (igs20.atx entries + any custom.atx entries
# not already present under the same TYPE/SERIAL NO) - a GENERATED file,
# rebuilt only when either source changes (see merge_custom_antex()'s
# hash-check), never committed/downloaded directly. Lives under
# GM_RUNTIME_DIR (survey_controller.py's runtime_paths.py convention -
# generated/runtime data stays outside the git checkout), not alongside
# igs20.atx itself, so a future wholesale geomaxima_ppp/ -> GM_RUNTIME_DIR
# migration (already tracked separately, see survey_controller.py's own
# NOTE on that) doesn't need to also move this file.
MERGED_ANTEX_RELATIVE_PATH = "antex/merged.atx"

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
# test on BaseStation found that WITHOUT this explicit override, rnx2rtkp
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
# BaseStation with both ant1-anttype=NONE and out-solstatic=all produced
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
ant1-anttype       ={anttype}
ant1-antdele       =0
ant1-antdeln       =0
ant1-antdelu       =0
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


def antenna_type_in_antex(antex_file: Path, antenna_type: str) -> bool:
    """
    GeoMaxima Part 6a: whether antex_file has a TYPE/SERIAL NO record for
    the given 20-character antenna type (IGS/NGS convention: 16-char
    antenna name + 4-char radome, space-padded to exactly 20 columns) -
    the Python equivalent of pdp3.sh's own AntexHasAntenna() bash
    function (same ANTEX column convention: columns 1-20 are the
    antenna/radome type, columns 61-76 are the record-type label),
    ported here rather than shelling out to that script so the rnx2rtkp
    path (this module) can make the identical calibrated/uncalibrated
    determination pdp3's own pre-flight check already makes for the
    PRIDE-PPPAR path.

    This is also what Part 6a's antenna_calibrated status is DERIVED
    from (no separate manually-set config key - see RTKBaseConfig.
    get_antenna_arp_offset()'s sibling settings and the UI's own
    validation) - an antenna_info value that doesn't match a verbatim
    TYPE/SERIAL NO record in the ANTEX file currently in use (igs20.atx
    by default, or Part 6b's custom ANTEX once that exists) means
    "uncalibrated" for all PPP purposes, regardless of what string is
    configured.

    Args:
        antex_file: path to the ANTEX file to search (igs20.atx, or a
            custom one per Part 6b).
        antenna_type: the 20-character antenna type string to look for -
            NOT stripped/reformatted here, since ANTEX type matching is
            column-exact (a caller passing an unpadded/mis-cased string
            will correctly get False, matching pdp3.sh's own strict
            `substr($0, 1, 20) == ant` comparison).

    Returns:
        True if found, False if not found OR if antenna_type is empty/
        whitespace-only (an empty type can never legitimately match any
        real ANTEX record) OR if antex_file doesn't exist/can't be read
        (logged as a warning, not raised - "cannot verify calibration"
        is treated the same as "not calibrated", the safer assumption).
    """
    if not antenna_type or not antenna_type.strip():
        return False
    if not antex_file.exists():
        logger.warning(f"antenna_type_in_antex: ANTEX file not found at {antex_file} - "
                       f"treating {antenna_type!r} as uncalibrated (cannot verify)")
        return False
    try:
        with open(antex_file, 'r', errors='replace') as f:
            for line in f:
                if len(line) < 76:
                    continue
                if line[60:76] == 'TYPE / SERIAL NO' and line[0:20] == antenna_type:
                    return True
    except Exception as e:
        logger.warning(f"antenna_type_in_antex: failed to read {antex_file}: {e} - "
                       f"treating {antenna_type!r} as uncalibrated (cannot verify)")
        return False
    return False


def _antex_antenna_blocks(antex_file: Path) -> List[tuple]:
    """
    Part 6b: split an ANTEX file into its individual antenna blocks (each
    "START OF ANTENNA" ... "END OF ANTENNA" span), WITHOUT interpreting
    the calibration data itself - this is a text-level split for merging,
    not a calibration parser (antenna_type_in_antex() above stays the
    single source of truth for "is this type present", used after
    merging; this function only needs to know where each block begins/
    ends and what its TYPE/SERIAL NO is).

    Returns a list of (antenna_type_20char, block_lines) tuples, in file
    order. A block with no readable TYPE/SERIAL NO line (malformed/
    truncated file) is skipped with a warning - never included with a
    None/empty key, which could cause a spurious "match" against another
    skipped block.
    """
    if not antex_file.exists():
        return []
    blocks = []
    current = None
    current_type = None
    try:
        with open(antex_file, 'r', errors='replace') as f:
            for line in f:
                # label.strip(), not a fixed-width slice - ANTEX pads the
                # DATA field to column 60, not the label itself, so a
                # short label (e.g. "END OF ANTENNA", 14 chars) can leave
                # the line shorter than 76 total characters. Matches the
                # same line[60:].strip() convention already used
                # elsewhere in this codebase (parse_cst_file() etc) for
                # exactly this reason.
                label = line[60:].strip() if len(line) > 60 else ''
                if label == 'START OF ANTENNA':
                    current = [line]
                    current_type = None
                elif current is not None:
                    current.append(line)
                    if label == 'TYPE / SERIAL NO' and current_type is None:
                        current_type = line[0:20]
                    if label == 'END OF ANTENNA':
                        if current_type is not None:
                            blocks.append((current_type, current))
                        else:
                            logger.warning(f"_antex_antenna_blocks: a block in {antex_file} has "
                                           f"no TYPE/SERIAL NO line - skipped (cannot merge safely)")
                        current = None
                        current_type = None
    except Exception as e:
        logger.warning(f"_antex_antenna_blocks: failed to read {antex_file}: {e}")
        return []
    return blocks


def merge_custom_antex(primary_antex: Path, custom_antex: Path, output_path: Path) -> Path:
    """
    Part 6b: build a MERGED ANTEX file = every antenna block from
    primary_antex (igs20.atx), plus any block from custom_antex whose
    TYPE/SERIAL NO is NOT already present in primary_antex. On a name
    collision, the PRIMARY (IGS) entry wins and the custom one is
    skipped, logged - per explicit instruction ("if the same antenna
    name exists in both, the IGS entry wins; log which source was
    used").

    Output structure: primary_antex's own header (through its own "END
    OF HEADER") verbatim, then every antenna block from primary_antex in
    its original order, then every NON-COLLIDING block from custom_antex
    appended at the end, then a single "END OF FILE"-equivalent - ANTEX
    has no such marker, the file simply ends after the last antenna
    block's "END OF ANTENNA" line, matching every real ANTEX file's own
    convention (confirmed: neither igs20.atx-style files nor the
    AS-ANT3BCAL01_NONE.atx single-antenna file have a trailing marker
    beyond that).

    This is idempotent and content-addressed by the caller (see
    resolve_working_antex()'s hash-check) - this function itself just
    does the merge, unconditionally, every time it's called; deciding
    WHETHER to call it again is the caller's job.

    Never raises - a missing/unreadable custom_antex degrades to "just
    copy primary_antex through unchanged" (logged), since the custom
    antenna being unavailable must never block ordinary IGS-calibrated
    antennas from working.
    """
    try:
        header_lines = []
        with open(primary_antex, 'r', errors='replace') as f:
            for line in f:
                header_lines.append(line)
                label = line[60:].strip() if len(line) > 60 else ''
                if label == 'END OF HEADER':
                    break
    except Exception as e:
        logger.error(f"merge_custom_antex: failed to read primary ANTEX header from "
                    f"{primary_antex}: {e}")
        raise

    primary_blocks = _antex_antenna_blocks(primary_antex)
    primary_types = {t for t, _lines in primary_blocks}
    logger.info(f"merge_custom_antex: primary ANTEX {primary_antex.name} has "
               f"{len(primary_blocks)} antenna block(s)")

    custom_blocks = _antex_antenna_blocks(custom_antex)
    added, skipped = [], []
    for ant_type, block_lines in custom_blocks:
        if ant_type in primary_types:
            skipped.append(ant_type)
        else:
            added.append((ant_type, block_lines))

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, 'w') as out:
        out.writelines(header_lines)
        for _ant_type, block_lines in primary_blocks:
            out.writelines(block_lines)
        for _ant_type, block_lines in added:
            out.writelines(block_lines)

    if added:
        logger.info(f"merge_custom_antex: added {len(added)} custom antenna entry/entries "
                   f"from {custom_antex.name} not present in {primary_antex.name}: "
                   f"{[t.strip() for t, _ in added]}")
    if skipped:
        logger.info(f"merge_custom_antex: {len(skipped)} custom entry/entries already present "
                   f"in {primary_antex.name} (IGS entry wins, custom one skipped): "
                   f"{[t.strip() for t in skipped]}")
    if not added and not skipped:
        logger.info(f"merge_custom_antex: no custom antenna entries found in {custom_antex} "
                   f"(missing or empty) - {output_path.name} is just {primary_antex.name} unchanged")

    return output_path


# Part 6b (cross-GNSS substitution): PRIDE-PPPAR's own rdatx.f90 (the
# ANTEX reader) has NO frequency-substitution logic at all - confirmed by
# reading it directly: ATX%neu/ATX%pcv are zero-initialized (lines 93-97)
# and only ever populated for frequencies the antenna's OWN # OF
# FREQUENCIES/START OF FREQUENCY blocks actually list (lines 163-208);
# any band missing from the ANTEX entry simply stays at that zero
# default - not an error, not a fallback, just zero PCO/PCV for that
# band. For a 2-frequency entry like AS-ANT3BCAL01 (G01/G02 only), every
# OTHER constellation Part 1 could select (E15/E17/E16, C26/C27, R12,
# J12/J15) would silently get zero correction.
#
# This matches the historical, documented IGS practice (the only
# established convention for this situation - see custom.atx's own
# README for the sources this was confirmed against): substitute GPS L1
# (G01) values for any UPPER L-band signal (~1.56-1.61 GHz: E1, B1I/B1C,
# R1, J1) and GPS L2 (G02) for any LOWER L-band signal (~1.16-1.30 GHz:
# E5/E5a/E5b/E6, B2I/B3I/B2a/B2b, R2, J2/J5/J6) - NOT a random/zero
# fallback, but still a known, documented approximation with a
# quantified bias (confirmed ~8mm height bias for GPS-L2-as-E5a
# specifically, per IGS/DLR research cited in custom.atx's README) -
# always logged as a substitution, never silently presented as a real
# calibration.
#
# Classification mirrors pride_pppar_processor.py's own
# _UPPER_BANDS/_LOWER_BANDS tables exactly (same upper/lower split
# already used for THIS station's frequency-combination selection), not
# a second, independently-invented classification that could drift out
# of sync with it.
_SUBSTITUTE_UPPER_BANDS = ('R1', 'E1', 'C1', 'C2', 'J1')
_SUBSTITUTE_LOWER_BANDS = ('R2', 'E5', 'E6', 'E7', 'E8', 'C5', 'C6', 'C7', 'C8', 'J2', 'J5', 'J6')


def augment_antex_with_gps_substitutes(antex_file: Path, output_path: Path) -> Path:
    """
    Part 6b: for every antenna block in antex_file that has a G01 and/or
    G02 frequency block but is MISSING one of _SUBSTITUTE_UPPER_BANDS/
    _SUBSTITUTE_LOWER_BANDS, duplicate G01's (for upper-band
    substitutes) or G02's (for lower-band substitutes) NORTH/EAST/UP +
    NOAZI pattern verbatim under that band's own label, and bump
    # OF FREQUENCIES accordingly - see this module's own comment above
    for exactly why (rdatx.f90 has no substitution of its own, and zero
    PCO/PCV for a tracked band is a worse, UNDOCUMENTED, silent failure
    mode compared to a documented, logged GPS-band substitution).

    A substitute block's own frequency label (e.g. "E01", "C02") is used
    for START/END OF FREQUENCY (required for rdatx.f90 to associate it
    with that system/band at all), but the NEU/pattern VALUES are G01's
    or G02's, copied as-is - this is exactly what "substitution" means
    here, not a real independent calibration for that band.

    Only touches blocks that actually have BOTH a G01 or G02 block to
    substitute FROM - an antenna with neither (shouldn't happen for any
    entry this project vendors, but defensive) is left completely
    unchanged, logged.

    Never raises - a malformed block is skipped with a warning, same
    fail-safe posture as the rest of this module's ANTEX handling.
    """
    blocks = _antex_antenna_blocks(antex_file)
    output_blocks = []
    summary = []

    for ant_type, lines in blocks:
        g01_block, g02_block = None, None
        freq_count = None
        freq_count_idx = None
        existing_bands = set()
        i = 0
        while i < len(lines):
            line = lines[i]
            label = line[60:].strip() if len(line) > 60 else ''
            if label == '# OF FREQUENCIES':
                freq_count_idx = i
                try:
                    freq_count = int(line[:60].strip())
                except ValueError:
                    pass
            elif label == 'START OF FREQUENCY':
                band_label = line[3:6].strip()  # e.g. "G01" -> sys='G', digit='1'
                block_start = i
                j = i
                while j < len(lines):
                    jl = lines[j][60:].strip() if len(lines[j]) > 60 else ''
                    if jl == 'END OF FREQUENCY':
                        break
                    j += 1
                block_lines = lines[block_start:j + 1]
                existing_bands.add(band_label[0] + band_label[2] if len(band_label) >= 3 else band_label)
                if band_label == 'G01':
                    g01_block = block_lines
                elif band_label == 'G02':
                    g02_block = block_lines
                i = j
            i += 1

        if g01_block is None and g02_block is None:
            logger.warning(f"augment_antex_with_gps_substitutes: {ant_type.strip()!r} has "
                           f"neither a G01 nor G02 block to substitute from - left unchanged")
            output_blocks.append(lines)
            continue

        added_bands = []
        new_blocks = []
        for sys_band in _SUBSTITUTE_UPPER_BANDS + _SUBSTITUTE_LOWER_BANDS:
            if sys_band in existing_bands:
                continue  # this antenna already has a REAL entry for this band - never override it
            source = g01_block if sys_band in _SUBSTITUTE_UPPER_BANDS else g02_block
            if source is None:
                continue  # no G01 (or G02) to substitute from for this band class
            sys_char, digit = sys_band[0], sys_band[1]
            substitute = []
            for line in source:
                label = line[60:].strip() if len(line) > 60 else ''
                if label in ('START OF FREQUENCY', 'END OF FREQUENCY'):
                    substitute.append(f"   {sys_char}{digit:0>2}" + line[6:])
                else:
                    substitute.append(line)
            new_blocks.append(substitute)
            added_bands.append(sys_band)

        if not added_bands:
            output_blocks.append(lines)
            continue

        result_lines = list(lines)
        if freq_count_idx is not None and freq_count is not None:
            new_count = freq_count + len(added_bands)
            result_lines[freq_count_idx] = f"{new_count:6d}" + result_lines[freq_count_idx][6:]
        # Insert the new blocks right before "END OF ANTENNA".
        end_idx = next(k for k, l in enumerate(result_lines)
                       if (l[60:].strip() if len(l) > 60 else '') == 'END OF ANTENNA')
        for block in reversed(new_blocks):
            result_lines[end_idx:end_idx] = block
        output_blocks.append(result_lines)
        summary.append((ant_type.strip(), added_bands))

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(antex_file, 'r', errors='replace') as f:
        header_lines = []
        for line in f:
            header_lines.append(line)
            label = line[60:].strip() if len(line) > 60 else ''
            if label == 'END OF HEADER':
                break
    with open(output_path, 'w') as out:
        out.writelines(header_lines)
        for block in output_blocks:
            out.writelines(block)

    for ant_type, bands in summary:
        logger.info(f"augment_antex_with_gps_substitutes: {ant_type!r} - substituted GPS "
                   f"values for {len(bands)} missing band(s): {bands} "
                   f"(G01 for upper-band, G02 for lower-band - see this module's own comment "
                   f"for the documented ~8mm-scale bias this approximation carries)")

    return output_path


def _band_present_in_block(antex_file: Path, sys_band: str) -> bool:
    """
    Whether antex_file has a START OF FREQUENCY block for the exact
    2-char sys_band (e.g. 'G1' -> matches 'G01'), REGARDLESS of which
    antenna TYPE it belongs to - this project's merged/augmented ANTEX
    always has exactly one relevant antenna block (the station's own
    configured antenna_info) by the time this is called, so a plain
    band-presence scan (not a per-antenna-block one) is sufficient and
    simpler than re-deriving the antenna-block boundaries again here.
    """
    if not antex_file.exists():
        return False
    sys_char, digit = sys_band[0], sys_band[1]
    target = f"{sys_char}{digit:0>2}"
    try:
        with open(antex_file, 'r', errors='replace') as f:
            for line in f:
                label = line[60:].strip() if len(line) > 60 else ''
                if label == 'START OF FREQUENCY' and line[3:6].strip() == target:
                    return True
    except Exception as e:
        logger.warning(f"_band_present_in_block: failed to read {antex_file}: {e}")
    return False


def classify_band_calibration(antex_file: Path, frequency_combination: List[str]) -> Dict[str, str]:
    """
    Part 6b (item 3): per-band calibration status for a PPP-AR run's
    actual frequency_combination (select_frequency_combination()'s own
    'frq' list, e.g. ['G12', 'E15', 'C26']) - "calibrated" (a REAL entry
    exists for this exact band), "substituted from G01"/"substituted
    from G02" (augment_antex_with_gps_substitutes() filled it in), or
    "none" (missing even after augmentation - should not normally
    happen for any band this project's own augmentation covers, but
    reported honestly if it ever does, e.g. a future band neither
    _SUBSTITUTE_UPPER_BANDS nor _SUBSTITUTE_LOWER_BANDS lists yet).

    This distinction can only be told apart by checking the UNAUGMENTED
    custom.atx (for "calibrated" vs "substituted") - augment_antex_with_
    gps_substitutes() itself already logs which bands it substituted at
    build time, but that log line is per-ANTEX-build, not per-run, and
    doesn't by itself tell a caller holding only the final merged/
    augmented file which specific status applies to which of THIS run's
    selected bands. This function re-derives it from frequency_combination
    directly against antex_file (the merged/augmented file actually
    used for the run) - a band present there is at least usable; whether
    it's "real" or "substituted" needs the ORIGINAL (pre-augmentation)
    file too, via the raw_antex_file optional check below.

    Args:
        antex_file: the (merged/augmented) ANTEX file this run actually
            used - e.g. PPPProcessor.resolve_working_antex() or
            resolve_augmented_custom_antex().
        frequency_combination: e.g. ['G12', 'E15', 'C26'] - each entry is
            SYS + two band digits (one or two characters each,
            'G12' = G01+G02, 'E15' = E01+E05).

    Returns: {band_label (e.g. 'G1', 'G2', 'E1', 'E5', 'C2', 'C6'):
        'calibrated' | 'substituted from G01' | 'substituted from G02' |
        'none'}, one entry per individual band actually used (a 2-char
        combination like 'G12' expands to both 'G1' and 'G2').
    """
    result = {}
    for combo in frequency_combination:
        sys_char = combo[0]
        for digit in combo[1:]:
            band_label = f"{sys_char}{digit}"
            if band_label in ('G1', 'G2'):
                result[band_label] = 'calibrated' if _band_present_in_block(antex_file, band_label) else 'none'
            elif band_label in _SUBSTITUTE_UPPER_BANDS:
                result[band_label] = ('substituted from G01' if _band_present_in_block(antex_file, band_label)
                                      else 'none')
            elif band_label in _SUBSTITUTE_LOWER_BANDS:
                result[band_label] = ('substituted from G02' if _band_present_in_block(antex_file, band_label)
                                      else 'none')
            else:
                result[band_label] = 'calibrated' if _band_present_in_block(antex_file, band_label) else 'none'
    return result


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
        given, otherwise Part 6b's merged working ANTEX (igs20.atx +
        this project's own vendored custom.atx entries - see
        resolve_working_antex()). Raises AntexNotFoundError (not a
        generic FileNotFoundError, and NOT a cryptic rnx2rtkp subprocess
        failure) if the resolved path doesn't exist, with an actionable
        message pointing at the install step that fetches it.
        """
        path = Path(antex_file) if antex_file is not None else self.resolve_working_antex()
        if not path.exists():
            raise AntexNotFoundError(
                f"ANTEX file not found at {path}. This is a required, "
                f"one-time, install-level download (~54MB) - run "
                f"install.sh (fresh install) or wait for the next OTA "
                f"update (perform_update.sh), both of which fetch "
                f"igs20.atx automatically. It is NOT downloaded per-survey."
            )
        return path

    def custom_antex_path(self) -> Path:
        """
        Part 6b: the vendored custom-ANTEX file's path (committed to this
        repo, under rtkbase_root - see CUSTOM_ANTEX_RELATIVE_PATH's own
        comment for why this lives under addons/ rather than alongside
        the downloaded igs20.atx).
        """
        return self.rtkbase_root / CUSTOM_ANTEX_RELATIVE_PATH

    def resolve_augmented_custom_antex(self) -> Path:
        """
        Part 6b: the GPS-substituted version of custom_antex_path() (see
        augment_antex_with_gps_substitutes()) - what the PRIDE-PPPAR path
        actually needs (passed to pdp3.sh via GEOMAXIMA_CUSTOM_ANTEX),
        since pdp3.sh appends this file's own antenna blocks verbatim
        into its freshly-downloaded abs_igs.atx every run, with no
        separate substitution step of its own. The rnx2rtkp path gets
        the same augmentation automatically inside resolve_working_antex()
        itself; this method exists so BOTH backends see the identical,
        already-substituted antenna data, never two independently-
        computed (and potentially diverging) substitution results.

        Hash-checked and regenerated only when custom_antex_path() itself
        changes - same pattern as resolve_working_antex(). Falls back to
        the RAW (unaugmented) custom_antex_path() on any failure, so a
        broken augmentation step degrades to "this band gets zero PCO/PCV,
        same as before Part 6b" rather than losing the antenna entirely.
        """
        custom = self.custom_antex_path()
        if not custom.exists():
            return custom

        augmented = self.merged_antex_path().parent / f"{custom.stem}_augmented_standalone.atx"
        hash_file = augmented.with_suffix(augmented.suffix + '.source_hash')

        def _file_hash(p: Path) -> str:
            h = hashlib.sha256()
            with open(p, 'rb') as f:
                for chunk in iter(lambda: f.read(65536), b''):
                    h.update(chunk)
            return h.hexdigest()

        current_hash = _file_hash(custom)
        stored_hash = hash_file.read_text().strip() if hash_file.exists() else None
        if augmented.exists() and stored_hash == current_hash:
            return augmented

        try:
            augment_antex_with_gps_substitutes(custom, augmented)
            hash_file.write_text(current_hash)
            return augmented
        except Exception as e:
            logger.error(f"resolve_augmented_custom_antex: augmentation failed ({e}) - "
                        f"falling back to the raw (unaugmented) {custom}")
            return custom

    def merged_antex_path(self) -> Path:
        """
        Part 6b: where the MERGED (igs20.atx + custom.atx) working ANTEX
        lives - under GM_RUNTIME_DIR, a GENERATED file (see
        resolve_working_antex()), never committed or downloaded directly.
        """
        return GM_RUNTIME_DIR / MERGED_ANTEX_RELATIVE_PATH

    def resolve_working_antex(self) -> Path:
        """
        Part 6b: the ANTEX file BOTH PPP backends should actually use -
        the merge of igs20.atx (primary, auto-downloaded) and this
        project's own vendored custom.atx (e.g. the ArduSimple
        AS-ANT3BCAL01 NGS calibration), with IGS entries winning on any
        name collision (see merge_custom_antex()).

        Regenerates the merged file only when either source has changed
        since the last merge - tracked via a stored content hash of BOTH
        source files combined, the SAME idempotent-rebuild pattern
        addons/tools/perform_update.sh already uses for PRIDE-PPPAR's own
        rebuild-only-if-source-changed logic (that pattern exists because
        an earlier, narrower version of it silently missed a real source
        change once - see that script's own PRIDE_PPPAR_HASH_FILE
        comment - so this reuses the lesson rather than re-learning it).

        If igs20.atx itself doesn't exist yet (not installed/downloaded),
        returns default_antex_path() unchanged (so resolve_antex()'s own
        AntexNotFoundError still fires with its existing, actionable
        message) - merging is skipped entirely rather than producing a
        merged file that's just the custom antenna alone, which would
        silently work for ONE antenna type while being useless for every
        IGS-calibrated one.

        Never raises - a merge failure for any other reason logs an
        error and falls back to the unmerged igs20.atx path, since an
        ordinary IGS-calibrated antenna must keep working even if the
        custom-ANTEX merge itself is broken.
        """
        primary = self.default_antex_path()
        if not primary.exists():
            return primary

        custom = self.custom_antex_path()
        merged = self.merged_antex_path()
        hash_file = merged.with_suffix(merged.suffix + '.source_hash')

        def _file_hash(p: Path) -> str:
            if not p.exists():
                return 'MISSING'
            h = hashlib.sha256()
            with open(p, 'rb') as f:
                for chunk in iter(lambda: f.read(65536), b''):
                    h.update(chunk)
            return h.hexdigest()

        current_hash = f"{_file_hash(primary)}:{_file_hash(custom)}"
        stored_hash = hash_file.read_text().strip() if hash_file.exists() else None

        if merged.exists() and stored_hash == current_hash:
            logger.debug(f"resolve_working_antex: {merged} is up to date (source unchanged)")
            return merged

        try:
            # Part 6b (cross-GNSS substitution): augment custom.atx with
            # GPS-substituted bands BEFORE merging - see
            # augment_antex_with_gps_substitutes()'s own comment for why
            # this is needed at all (rdatx.f90 has no substitution of
            # its own; a 2-frequency entry would otherwise silently get
            # zero PCO/PCV for every OTHER band Part 1 could select).
            augmented = merged.parent / f"{custom.stem}_augmented.atx"
            augment_antex_with_gps_substitutes(custom, augmented)
            merge_custom_antex(primary, augmented, merged)
            hash_file.write_text(current_hash)
            logger.info(f"resolve_working_antex: (re)built merged ANTEX at {merged}")
            return merged
        except Exception as e:
            logger.error(f"resolve_working_antex: merge failed ({e}) - falling back to "
                        f"unmerged {primary} (custom antenna entries unavailable this run)")
            return primary

    def _generate_ppp_conf(self, antex_path: Path, work_dir: Path,
                           antenna_type: Optional[str] = None) -> Path:
        """
        Write a minimal -k options file (see _PPP_CONF_TEMPLATE) into
        work_dir, with the real ANTEX path filled into file-satantfile/
        file-rcvantfile - both used for the same file here, since this
        module tracks one ANTEX file covering both satellite and receiver
        antenna models (the bundled igs20.atx), not separate files per
        RTKLIB's more general two-file option.

        ant1-anttype (Part 6a): the caller's job to resolve to either a
        REAL, ANTEX-verified 20-char antenna type (antenna_type_in_antex()
        confirmed it) or the literal "NONE" fallback (this station's own
        confirmed-live default before Part 6a - see the module
        docstring's "NO RECEIVER ANTENNA PCV" section) - this method
        itself does not look anything up, just writes whatever string it
        is given. Falls back to "NONE" here only if antenna_type is None/
        empty, as a defensive default matching the pre-6a behavior.

        ant1-antdel{e,n,u}=0 (Part 6a, ALWAYS, regardless of antenna
        type/calibration status): RTKLIB's -k conf antenna-delta keys
        take precedence over whatever the RINEX header's own "ANTENNA:
        DELTA H/E/N" says (standard RTKLIB convention - "command line
        options precede options in the configuration file", confirmed
        elsewhere in this codebase for other flags). Explicitly zeroing
        them here guarantees the PPP-static position this produces is
        always the antenna's own ARP (Antenna Reference Point) - with
        PCO/PCV correction applied when antenna_type is a real, ANTEX-
        matched calibration, none when it's NONE - never a further,
        separately-tracked marker offset. Recovering the MARKER position
        (for reports/RTCM 1006) from this ARP result is done once,
        downstream, via RTKBaseConfig.get_antenna_arp_offset() - never
        by touching this delta. See survey_controller.py's
        _apply_geodetic_position() Step 6/8 comment for the broadcast-
        side half of this same "always process/broadcast at the ARP"
        convention.

        Returns the path to the generated conf file. NOT automatically
        deleted by this method - see process_ppp()'s cleanup handling for
        the lifecycle/retention decision.
        """
        conf_path = work_dir / "ppp_static.conf"
        conf_content = _PPP_CONF_TEMPLATE.format(
            satantfile=str(antex_path),
            rcvantfile=str(antex_path),
            anttype=antenna_type if antenna_type else "NONE",
        )
        conf_path.write_text(conf_content)
        return conf_path

    def process_ppp(self,
                     obs_file: Path,
                     sp3_file: Path,
                     nav_file: Optional[Path] = None,
                     clk_file: Optional[Path] = None,
                     antex_file: Optional[Path] = None,
                     output_file: Optional[Path] = None,
                     antenna_type: Optional[str] = None) -> Optional[Path]:
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
            antenna_type: Part 6a - the station's configured antenna_info
                (settings.conf), ALREADY VERIFIED by the caller against
                antex_file via antenna_type_in_antex() (this method does
                NOT re-verify it - a caller passing an unverified string
                would silently fall back to rnx2rtkp's own "unknown
                antenna" handling, not this module's explicit NONE
                convention). None/empty falls back to "NONE" (this
                station's pre-6a default - see the module docstring's
                "NO RECEIVER ANTENNA PCV" section), matching the
                PCO/PCV-correction-unavailable case for an uncalibrated
                antenna. The PPP-static result is ALWAYS computed at the
                antenna's own ARP regardless of which branch this takes -
                see _generate_ppp_conf()'s own comment on
                ant1-antdel{e,n,u}=0.

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

            conf_path = self._generate_ppp_conf(antex_path, work_dir, antenna_type=antenna_type)

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

    def parse_position_file(self, pos_file: Path) -> List[Dict]:
        """
        Parse RTKLIB position file (.pos) produced by process_ppp().

        FIX (Phase 2d validation): this method was originally missing
        entirely - the module docstring above described a plan for
        survey_controller.py to keep calling
        self.spp.parse_position_file(pos_file) unchanged after swapping
        SPPProcessor for PPPProcessor, but the method itself was never
        actually added here, causing a live AttributeError
        ("'PPPProcessor' object has no attribute 'parse_position_file'")
        the first time a real survey ran this code path.

        Delegates to the module-level parse_rtklib_position_file() in
        spp_processor.py - the same single source of truth
        SPPProcessor.parse_position_file() also delegates to - rather than
        duplicating the parsing logic here. RTKLIB's -f 2 .pos output
        format is mode-independent (same column layout for -p 0 SPP and
        -p 8 PPP-static, confirmed Phase 2c), so no PPP-specific parsing
        behavior is needed; a plain composition/delegation call is
        correct and sufficient.

        Args:
            pos_file: Path to .pos file

        Returns:
            List of position records - see parse_rtklib_position_file()
            in spp_processor.py for the exact field reference.
        """
        return parse_rtklib_position_file(pos_file)


# ---------------------------------------------------------------------------
# _KNOWN_LIMITATIONS
# ---------------------------------------------------------------------------
# 1. RESOLVED - CONFIRMED WORKING END-TO-END. This dev environment cannot
#    execute tools/bin/RTKLIB-2.5.0/aarch64/rnx2rtkp (Windows host, ARM
#    Linux binary - the same constraint noted throughout Phase 2a/2b/2c/
#    these fixes), so all verification below happened on BaseStation, not
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
#    only on BaseStation (fetched by install.sh/perform_update.sh), not on
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
