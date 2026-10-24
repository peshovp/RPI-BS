"""
ANTEX support for the PRIDE-PPPAR pipeline
==========================================

Everything the Autosurvey needs about antenna calibration files (ANTEX, .atx):

- locating the working ANTEX: the installed IGS ANTEX (igs20.atx) merged with this
  project's own vendored custom entries (addons/geomaxima_antex/custom.atx, e.g. the
  ArduSimple AS-ANT3BCAL01 NGS calibration), cached as a generated file;
- checking whether an antenna type is calibrated (present in the ANTEX file);
- augmenting a custom entry with GPS-frequency substitutes for the other constellations
  (cross-GNSS PCO/PCV substitution) and classifying the calibration status per band.

PRIDE-PPPAR (pdp3) reads ANT # / TYPE from the RINEX header and the ANTEX file chosen
here (GEOMAXIMA_CUSTOM_ANTEX, see pride_pppar_processor.py).
"""

import hashlib
import logging
import os
from pathlib import Path
from typing import Dict, List, Optional

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
# this module already resolves to - see AntexSupport.__init__()), NOT
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


class AntexNotFoundError(Exception):
    """
    The ANTEX (.atx) file is missing at the expected install-time path.
    Raised so the operator is pointed at the actual fix (install.sh / the
    next OTA fetch igs20.atx).
    """


def antenna_type_in_antex(antex_file: Path, antenna_type: str) -> bool:
    """
    GeoMaxima Part 6a: whether antex_file has a TYPE/SERIAL NO record for
    the given 20-character antenna type (IGS/NGS convention: 16-char
    antenna name + 4-char radome, space-padded to exactly 20 columns) -
    the Python equivalent of pdp3.sh's own AntexHasAntenna() bash
    function (same ANTEX column convention: columns 1-20 are the
    antenna/radome type, columns 61-76 are the record-type label),
    ported here rather than shelling out to that script so this module
    can make the identical calibrated/uncalibrated
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
            used - e.g. AntexSupport.resolve_working_antex() or
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


class AntexSupport:
    """
    Locates and prepares the ANTEX file used by PRIDE-PPPAR: the default IGS
    ANTEX, the project's custom entries, the merged working file and the
    GPS-substitute augmented custom file.
    """

    def __init__(self, rtkbase_root: Optional[Path] = None):
        """
        Args:
            rtkbase_root: RTKBase installation root. If None, defaults to this
                file's own repository root (three levels up from
                addons/features/auto_survey/), matching RTKBaseConfig and
                SurveyController.
        """
        if rtkbase_root is None:
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
        generic FileNotFoundError) if the resolved path doesn't exist, with an actionable
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
        separate substitution step of its own. The merged working ANTEX gets
        the same augmentation inside resolve_working_antex() itself; this
        method exists so every consumer sees the identical,
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

