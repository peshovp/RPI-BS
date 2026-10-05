# GeoMaxima custom ANTEX (Part 6b)

This directory holds antenna calibration entries that GeoMaxima vendors
directly into this repo, for antennas that have a published absolute
calibration but aren't (yet, or ever) folded into the IGS's own bulk
`igs20.atx`.

## Why this exists

`igs20.atx` (downloaded automatically at install/OTA time - see
`install.sh`/`addons/tools/perform_update.sh`) only carries IGS-adopted
calibrations. A number of real surveying antennas - including the
ArduSimple `AS-ANT3B-CAL-01` this file currently covers - are instead
calibrated by NGS (the US National Geodetic Survey) and published
separately at [geodesy.noaa.gov/ANTCAL](https://geodesy.noaa.gov/ANTCAL/).
Without an entry for the antenna actually in use, both PPP backends
(`rnx2rtkp` and PRIDE-PPPAR's `pdp3`) fall back to a zero PCO/PCV
correction (the project's existing `ADVNULLANTENNA`/`NONE` convention) -
correct and safe, but leaving centimeter-level accuracy on the table for
an antenna that actually has a real calibration available.

## `custom.atx`

A single, small ANTEX 1.4 file (not a bulk download - NGS calibrations
are fetched and vendored one antenna at a time, verbatim, as they're
needed) containing:

- **AS-ANT3BCAL01 NONE** (ArduSimple AS-ANT3B-CAL-01) - fetched verbatim
  from `https://geodesy.noaa.gov/ANTCAL/LoadFile?file=AS-ANT3BCAL01_NONE.atx`
  on 2026-10-02. Provenance (source URL, download date, and the
  single-antenna file's own sha256sum before the provenance comment was
  added) is recorded as ANTEX `COMMENT` lines inside the file's own
  header - open it and read the top few lines.

  G01/G02 (L1/L2) phase-center variations only - the entry covers GPS
  L1/L2, not L5, GLONASS, Galileo, or BeiDou.

  **This matters in practice, not just in theory**: confirmed by reading
  PRIDE-PPPAR's own ANTEX reader (`src/lib/rdatx.f90:93-97, 163-208`)
  directly, it has NO cross-GNSS substitution logic of its own - a band
  missing from the antenna's own `# OF FREQUENCIES` list simply gets
  ZERO PCO/PCV, silently. `ppp_processor.py`'s
  `augment_antex_with_gps_substitutes()` fills this gap ITSELF, before
  either backend ever sees the file: GPS L1 (G01) values are substituted
  for every upper L-band signal (Galileo E1, BeiDou B1I/B1C, GLONASS R1,
  QZSS J1) and GPS L2 (G02) for every lower L-band signal (Galileo
  E5/E5a/E5b/E6, BeiDou B2I/B3I/B2a/B2b, GLONASS R2, QZSS J2/J5/J6) -
  the documented historical IGS convention for exactly this situation
  (confirmed via IGS/DLR research - a quantified ~8mm height-bias scale
  for GPS-L2-as-Galileo-E5a specifically, still far better than the zero
  correction this is replacing). Logged per band, every run
  (`classify_band_calibration()`), carried into the Autosurvey page's
  PPP-AR attempt history as an explicit "antenna calibrated for GPS
  L1/L2 only" note - never silent, and never presented as if it were a
  real calibration for that band.

**To enter this antenna on a station**: set `antenna_info` (Main Service
settings) to exactly `AS-ANT3BCAL01   NONE` - 13 characters antenna name,
3 spaces, 4 characters radome, 20 characters total. The exact string
matters: ANTEX lookup is column-exact, not fuzzy.

## How it's used

Neither PPP backend reads this file directly - it's merged into the
file each backend actually uses:

- **rnx2rtkp**: `ppp_processor.py`'s `resolve_working_antex()` builds a
  single merged ANTEX (`igs20.atx`'s own entries + any entry from
  `custom.atx` not already present under the same `TYPE / SERIAL NO`)
  under `GM_RUNTIME_DIR` (`/var/lib/rtkbase/antex/merged.atx` in
  production), regenerated only when either source file's content
  changes (hash-checked, same idempotent-rebuild pattern
  `addons/tools/perform_update.sh` already uses for PRIDE-PPPAR's own
  rebuild-only-if-source-changed logic).
- **PRIDE-PPPAR (pdp3)**: has no persistent ANTEX file to merge into -
  it downloads its own satellite+receiver ANTEX fresh, into its own
  per-run work directory, every single run. `pdp3.sh`'s own locally-
  patched antenna-check step (`GEOMAXIMA_CUSTOM_ANTEX` env var, set by
  `pride_pppar_processor.py`'s `process_ppp_ar()`) appends `custom.atx`
  into that freshly-downloaded file, per run, right before the
  receiver-antenna check - never persisted, since there's nothing
  persistent to merge into for this backend.

On any name collision between `igs20.atx` and `custom.atx`, the **IGS
entry always wins** - this file exists to fill gaps, never to override
an antenna IGS already calibrates.

## Adding another antenna

1. Find its calibration at <https://geodesy.noaa.gov/ANTCAL/> (or the
   relevant national/institutional calibration authority) and fetch its
   single-antenna ANTEX export, verbatim.
2. Confirm its exact 20-character `TYPE / SERIAL NO` string.
3. Append the ENTIRE `START OF ANTENNA` ... `END OF ANTENNA` block (not
   the file's own header) into `custom.atx`, after the existing
   entry/entries. Record the source URL, download date, and a checksum
   of the fetched data as new `COMMENT` lines - follow the existing
   entry's own provenance comment as the template.
4. Re-run `tests/` (or the scratchpad `test_part6b_custom_antex.py`-style
   checks) to confirm the new entry is found correctly and doesn't
   collide with anything already in `igs20.atx`.
