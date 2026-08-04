# Design: Migrating Auto Survey-In from SPP to PPP-Static

**Status:** design only — no code changes made. Read-only investigation performed against `addons/features/auto_survey/` as it exists on `main` at the time of writing.

---

## 1. Current `SPPProcessor` interface (drop-in replacement target)

Read in full: `addons/features/auto_survey/spp_processor.py` (267 lines).

```python
class SPPProcessor:
    def __init__(self, rnx2rtkp_path: Optional[str] = None):
        # auto-discovers rnx2rtkp via find_rtklib_tool() if not given

    def process_spp(self,
                     obs_file: Path,
                     nav_file: Optional[Path] = None,
                     output_file: Optional[Path] = None) -> Optional[Path]:
        # builds: [rnx2rtkp, -p, "0", -m, "15", -f, "2", -o, <output_file>, <obs_file>, [<nav_file>]]
        # subprocess.run(..., timeout=600)
        # returns Path to .pos file, or None on any failure (nonzero exit,
        # missing output file, output file < 100 bytes)

    def parse_position_file(self, pos_file: Path) -> List[Dict]:
        # returns list of dicts: date/time or week/seconds, lat, lon, height,
        # Q, ns, sdn, sde, sdu, [sdne, sdeu, sdun, age, ratio]
```

**A `PPPProcessor` must expose exactly these two methods with the same signatures** so `survey_controller.py`'s call sites (`self.spp.process_spp(obs_file, nav_file)` at line 514, `self.spp.parse_position_file(pos_file)` at line 524) work unmodified when `self.spp = SPPProcessor()` (line 81) is swapped for `self.spp = PPPProcessor()`. `parse_position_file()` does not need to change at all — RTKLIB's `-f 2` output format is identical regardless of `-p` mode, so the existing parser is reusable as-is.

Failure-handling contract to preserve: return `None`/`[]` on any failure, never raise — `survey_controller.py`'s `_perform_update()` (line 478) treats a `None`/falsy return as a normal "retry next cycle" condition, not a fatal error, and this must keep working since PPP has additional failure modes (missing precise products) that SPP never had.

## 2. `rinex_converter.py` — RINEX output format and dual-frequency question

Read in full: `addons/features/auto_survey/rinex_converter.py` (222 lines).

`RINEXConverter.convert_raw_to_rinex_obs()` shells out to `convbin -r <format> -d <dir> -f 2 <input>` with no explicit RINEX version flag — this uses `convbin`'s default output version (RINEX 3.x in RTKLIB 2.4.3/demo5-era `convbin`). It does not restrict observation types or frequency bands via any `-s`/`-y` filter flag.

**Receiver hardware, confirmed from `addons/features/gnss_config/zedf9p_config.py`:** this is a u-blox **ZED-F9P**, configured (via UBX `CFG-VALSET`) to output RTCM3 **MSM7** messages for GPS (`TYPE1077`), GLONASS (`TYPE1087`), Galileo (`TYPE1097`), and BeiDou (`TYPE1127`) — MSM7 is RTKLIB's highest-precision multi-signal message set. The ZED-F9P is a dual-frequency (L1/L2) receiver by hardware spec, and its raw logging path (`str2str_file.service`, format `ubx`) captures `UBX-RXM-RAWX`, which carries all tracked signals including L2C.

**Caveat — not independently verified this session:** I could not execute `convbin` or `rnx2rtkp` in this environment (dev machine, no aarch64 execution; `tools/bin/RTKLIB-2.5.0/aarch64/rnx2rtkp` is present but this is a Windows dev host that cannot run an ARM Linux ELF binary, and `strings` against it did not yield readable usage text to confirm `-p 8` support directly). The dual-frequency claim rests on receiver hardware capability and message-type configuration, not on an actual RINEX header inspected from a live capture. **Phase 2a below includes a mandatory verification step against a real raw log file on the actual Pi hardware before any further phase proceeds** — do not treat dual-frequency RINEX output as confirmed until that step runs.

## 3. `survey_controller.py` — call site and required changes

Read in full: `addons/features/auto_survey/survey_controller.py` (875 lines).

Relevant lines:
- Line 28: `from .spp_processor import SPPProcessor`
- Line 81: `self.spp = SPPProcessor()`
- Line 514: `pos_file = self.spp.process_spp(obs_file, nav_file)`
- Line 524: `positions = self.spp.parse_position_file(pos_file)`
- Line 534: `quality_positions = [p for p in positions if p.get('Q') in (1, 2, 4, 5)]`

**Minimal required changes to swap in PPP:**
1. Import `PPPProcessor` alongside/instead of `SPPProcessor`.
2. Line 81: instantiate `PPPProcessor` (needs precise-product paths — see §4).
3. Line 396 (`logger.info("Using RINEX conversion workflow (RTKBase raw logs → RINEX → SPP)")`) and other SPP-labeled log strings are cosmetic but should be updated for accuracy — not functional.
4. **Convergence/timing behavior (real semantic change, not cosmetic):** PPP-static does not produce a usable fix in the first few epochs the way SPP does — it needs a convergence period (typically 30–60+ minutes for float-ambiguity PPP to stabilize to sub-decimeter, several hours to fully converge to cm-level). The existing `update_schedule` (line 109–113: 15-min interim updates for the first 6 hours) would run `PPPProcessor` repeatedly on a still-converging solution, which is wasteful (each call reprocesses the entire accumulated dataset from scratch — no epoch-by-epoch incremental state) and would show the user a mid-convergence interim position that looks like an outlier/degrading-then-improving trend rather than the smooth SPP noise floor it's used to today. **Recommendation:** widen the interim-update interval when in PPP mode (e.g., hourly from the start, not 15-minute), and add an explicit "still converging" quality flag surfaced to the UI so early interim positions aren't mistaken for the final accuracy. This requires a small `update_schedule` branch keyed on processing mode — flagged as a Phase 2d item below, not bundled into the processor swap itself.
5. Line 534's quality-flag filter (`Q in (1,2,4,5)`) — PPP-static in RTKLIB reports `Q=1` (its convergence-completed float/fixed solution state differs from RTK's meaning of `Q=1`; consult the specific rnx2rtkp version's `readsol`/`outsol` quality coding — RTKLIB uses the same Q column across all modes, where for PPP `Q=5` also occurs pre-convergence). This filter is permissive enough (accepts 1,2,4,5) that it likely does not need changing, but the interim update's threshold on `estimate.horizontal_std_meters` (used implicitly by `PositionEstimator`'s outlier rejection, not shown above but present in `position_estimator.py`) may need retuning since PPP's std devs during convergence are structurally different from SPP's.

## 4. `PPPProcessor` design

New file: `addons/features/auto_survey/ppp_processor.py`.

```python
class PPPProcessor:
    def __init__(self,
                 rnx2rtkp_path: Optional[str] = None,
                 products_dir: Path = ...,      # dir containing downloaded sp3/clk/atx
                 antex_path: Optional[Path] = None):
        # same auto-discovery pattern as SPPProcessor for rnx2rtkp
        # products_dir/antex_path are new — must be supplied or auto-resolved
        # to the latest downloaded product set (see PPPDownloader, §5)

    def process_ppp(self, obs_file, nav_file=None, output_file=None,
                     sp3_file=None, clk_file=None) -> Optional[Path]:
        # rnx2rtkp -p 8 -m 15 -f 2 -o <output_file>
        #   -ti 30                      # optional: decimate to match sp3/clk sample rate
        #   <obs_file> [<nav_file>] <sp3_file> <clk_file> <antex_path>
        ...

    def parse_position_file(self, pos_file):
        # delegates to / reuses the existing SPPProcessor.parse_position_file
        # logic verbatim (output format is identical for -f 2 regardless of -p mode)
```

**Command-line / processing-option requirements for `-p 8` (ppp-static):**

RTKLIB's `rnx2rtkp` reads processing options either from CLI flags or (much more completely) from a `.conf` file passed via `-k <optsfile>`. Given the number of PPP-specific options that have no CLI shorthand (tropo estimation mode, ionosphere-free combination, ambiguity resolution mode, ANTEX path, PCV corrections), **this design proposes using a `.conf` file rather than trying to express everything via flags** — mirroring the pattern already established by the repo's own stock `web_app/rtklib_configs/rtkbase_ppp-static_default.conf` (confirmed present in this repo, currently used only by the unrelated `rtkrcv`-based real-time config picker in `web_app/ConfigManager.py`/`RtkController.py`, not by Auto Survey-In).

Key options that file already sets correctly for PPP-static and that this new integration should adopt (values taken directly from that file, confirmed by reading it this session):
- `pos1-posmode = ppp-static` (mode 8)
- `pos1-frequency = l1+l2+l5` — dual/triple-frequency, ionosphere-free combination implied by PPP mode
- `pos1-ionoopt = dual-freq` — ionosphere-free linear combination (no external ionosphere model needed when dual-freq is available)
- `pos1-tropopt = saas` — Saastamoinen tropospheric model as a priori, refined by estimation
- `pos1-sateph = brdc` — **this stock file still says `brdc`; for real PPP this MUST be changed to `precise`** (this is the single most important option to get right — using broadcast ephemeris in PPP mode defeats the entire purpose)
- `pos2-armode = continuous` — **ambiguity resolution is enabled in the stock file.** Per this task's explicit instruction to default to float-only unless RTKLIB has a simple native AR option: standard `rnx2rtkp`/demo5-build PPP-AR requires uncalibrated phase bias (UPD) products that are not part of the SP3/CLK/ATX product set this design proposes downloading (UPD products are a separate, much less universally available IGS product, typically only from specific analysis centers e.g. CNES/Wuhan with extra processing). **Recommendation: set `pos2-armode = off` for the initial PPP-static implementation** — this is the "big-endeavor PPP-AR" the task explicitly says to avoid; float-ambiguity PPP-static still achieves cm-to-low-dm level static accuracy over 24h+, which is already a large improvement over SPP's meter-level result.
- **ANTEX (`.atx`) file: required, not optional.** `file-*` options in the stock conf leave `file-satantfile`/`file-rcvantfile` blank — these must be populated with a path to an IGS ANTEX file (e.g., `igs20.atx`) for satellite PCO/PCV corrections; without it, PPP solutions carry a systematic bias of several centimeters to a decimeter depending on satellite geometry. Receiver antenna PCV (if the exact antenna model is in the ANTEX file) further refines accuracy but is less critical for a fixed base than satellite PCO/PCV.
- `ant1-postype`/`ant1-pos1..3`: the stock file has these as placeholder/blank (`postype=llh`, `pos1=90`) — for a **static base station**, the a priori position should be set from the current best-known `settings.conf` position (or `single`/`posfile` mode if starting from scratch) so PPP-static converges around a sane initial estimate rather than an arbitrary default.

**Concrete plan:** ship a new template `addons/features/auto_survey/ppp_static_survey.conf`, derived from the stock `rtkbase_ppp-static_default.conf` but with `pos1-sateph=precise`, `pos2-armode=off`, and `file-satantfile`/`file-rcvantfile` pointed at a downloaded/bundled ANTEX file, then invoke `rnx2rtkp -k <that conf> -p 8 ...` (the `-k` conf values can still be overridden by trailing CLI flags per RTKLIB convention, so `-p 8` on the CLI is redundant-but-harmless belt-and-suspenders against a stale conf file).

## 5. `ppp_downloader.py` — precise product acquisition (new module)

**This module does not exist anywhere in the current codebase or in the `OLD AutoSurvey/` folder** (confirmed by exhaustive repo-wide search in a prior session) — it is 100% new capability, not a restoration of anything.

### Product sources (no-registration or simple-registration mirrors)

| Source | Auth | Notes |
|---|---|---|
| **CDDIS (NASA)** | Free Earthdata Login (one-time registration, machine-to-machine via `.netrc` + bearer token, or `curl -n` with `.netrc`) | The canonical/most complete IGS archive. Auth flow: register at urs.earthdata.nasa.gov, then either (a) generate a long-lived token in the Earthdata UI and send it as `Authorization: Bearer <token>`, or (b) use `.netrc`-based HTTP Basic auth against `urs.earthdata.nasa.gov` combined with CDDIS's redirect-based session handshake (`.netrc` + `.urs_cookies` + `-L` redirect-follow in curl/wget). This is scriptable and stable but does require the one-time account. |
| **IGN (France, `igs.ign.fr`)** | None — anonymous FTP/HTTPS | Mirrors the same IGS final/rapid/ultra-rapid products. No account needed; simplest to automate. Good primary choice for a no-registration requirement. |
| **Wuhan University (WHU, `igs.gnsswhu.cn`)** | None — anonymous FTP | Also mirrors IGS products, geographically closer for some regions, useful as a fallback if IGN is unreachable. |

**Recommendation: IGN as primary (no auth, simplest automation), WHU as fallback, CDDIS as a third fallback if the operator is willing to do the one-time Earthdata registration** (worth it long-term since CDDIS has the best uptime/completeness track record, but not a hard requirement for a working v1).

### Product latency tiers

| Tier | Latency | Accuracy | Use for this feature? |
|---|---|---|---|
| Final | ~12–18 days | Best (orbit ~2.5cm, clock ~75ps) | Reprocessing pass only (see below) — too slow for the primary survey result |
| Rapid | ~17–41 hours | Near-final (orbit ~2.5cm, clock ~75ps, slightly less consistent) | **Primary choice for a 24–48h survey window** — available well within the survey's own timeframe |
| Ultra-rapid (observed half) | Real-time (updated every 6h, observed half ~3h old) | Slightly worse than rapid but usable | Fallback for the *initial* interim updates during the first ~24-41h before rapid products for that day become available |
| Ultra-rapid (predicted half) | Real-time | Materially worse (predicted orbits/clocks degrade with prediction horizon) | Avoid for final results; acceptable only for a rough interim "still converging" display value |

**Proposed strategy for a 24–48h static survey:**
1. During the survey, use whatever tier is available for the calendar day(s) spanned by the collected data — this will typically mean **ultra-rapid observed** for the most recent few hours and **rapid** for anything more than ~2 days old relative to "now."
2. At survey finalization, attempt to fetch **rapid** products for the full survey window (should be available by then, since a 24-48h survey's oldest data is already 1-2 days old by completion time).
3. **Add an optional "reprocess with final products" step**, run manually or via a scheduled job ~14-18 days after survey completion, that re-downloads final products for the exact date range and reprocesses the already-archived RINEX files (the raw/RINEX files should be retained, not deleted, specifically to make this possible — this is a deliberate change from current behavior, which deletes/stops logging raw data after survey completion via `_stop_file_logging()`). This is proposed as a distinct, separate, opt-in Phase (2e below), not part of the initial migration.

### File naming / URL construction

IGS SP3/CLK products are named by **GPS week + day-of-week** (legacy) or, since the 2022 long-filename convention, by **ISO year + day-of-year**. Both conventions are still in active use across mirrors as of product-generation dates in this repo's expected operating window, so the downloader must support both:

- Legacy short form: `igr{WWWWD}.sp3.Z` / `igr{WWWWD}.clk.Z` (rapid), `igu{WWWWD}_{HH}.sp3.Z` (ultra-rapid, HH = 00/06/12/18Z), `igs{WWWWD}.sp3.Z` (final) — `WWWW` = 4-digit GPS week, `D` = single-digit day-of-week (0=Sunday).
- Long form (2022+ convention): `IGS0OPSRAP_{YYYYDDD}0000_01D_15M_ORB.SP3.gz` and analogous `_CLK.CLK.gz` — `YYYY` = year, `DDD` = day-of-year, product-type infix (`RAP`/`ULT`/`FIN`) distinguishes tier.
- GPS week/day-of-week is computed from a calendar date via: GPS epoch = 1980-01-06 (Sunday); `gps_week = (date - gps_epoch).days // 7`; `day_of_week = (date - gps_epoch).days % 7`.

**Decompression:** legacy files are Unix-`compress`'d (`.Z` suffix, requires `unlzw`/`uncompress` — not the same as gzip; Python's stdlib does not decompress `.Z` natively, needs either shelling out to `uncompress`/`gzip -d` with LZW support, or a small pure-Python LZW decompressor / the `unlzw3` PyPI package). Long-form files are standard gzip (`.gz`, decompressible via stdlib `gzip` module directly).

### Proposed `ppp_downloader.py` interface

```python
class PPPDownloader:
    def __init__(self, products_dir: Path, mirror: str = "ign"):
        ...

    def fetch_products(self, start_time: datetime, end_time: datetime,
                        tier: str = "auto") -> Optional[Dict[str, Path]]:
        """
        Downloads SP3 + CLK covering [start_time, end_time].
        tier: "final" | "rapid" | "ultra-rapid" | "auto" (picks the best
              available tier per the latency table above, based on how old
              start_time/end_time are relative to now).
        Returns {"sp3": Path, "clk": Path} or None on failure (network error,
        product not yet published, mirror unreachable).
        """

    def ensure_antex(self) -> Optional[Path]:
        """
        Returns path to a bundled or previously-downloaded ANTEX file.
        Unlike SP3/CLK, ANTEX changes rarely (new IGS conventions every few
        years) - propose BUNDLING a current igs20.atx in the repo (~a few
        hundred KB) rather than downloading it fresh every survey, with an
        optional refresh-check.
        """
```

## 6. Impact on atomic-write / state_manager / config_manager / geoid logic

**Confirmed: none of these need to change.** Verified by reading the actual call sites in `survey_controller.py`:

- `RTKBaseConfig.update_position()` (in `rtkbase_config.py`) is called with `(lat, lon, height)` regardless of how that estimate was produced — PPP or SPP, the interface is identical (line 579, 685, 744). No change needed.
- `StateManager` (`state_manager.py`) stores whatever `position`/`position_std`/`quality_metrics` dicts `_perform_update()` builds (lines 601-619) — these are plain floats built from `estimate.*` attributes of a `PositionEstimate` object; `PositionEstimator`/`PositionEstimate` (in `position_estimator.py`, confirmed byte-identical across OLD/CURRENT in prior investigation) don't care what upstream processing produced the raw position/std-dev list they're averaging. No change needed, **provided** `PPPProcessor.parse_position_file()` returns records in the same dict shape (`lat`, `lon`, `height`, `Q`, `ns`, `sdn`, `sde`, `sdu`, ...) that `SPPProcessor.parse_position_file()` does — which is guaranteed by RTKLIB's `-f 2` output format being mode-independent (confirmed in §1).
- `ConfigManager`/`GeoidCorrector`: neither is in the position-processing path at all — `ConfigManager` handles antenna-position writes via a separate code path (`config.set_antenna_position`, used by other features per its docstring, not by `SurveyController` directly — `SurveyController` uses `RTKBaseConfig.update_position()` instead), and `GeoidCorrector` only converts the *already-computed* ellipsoidal height to orthometric for display (§3 of `survey_controller.py`, lines 554-568) — it has no dependency on how that ellipsoidal height was derived. No change needed.
- **One soft impact, not a required change:** `PositionEstimator`'s outlier-rejection threshold (`outlier_threshold=3.5`, `min_epochs=50`, set at `survey_controller.py` line 82) was tuned against SPP's noise characteristics. PPP's per-epoch scatter during convergence is structurally different (large early, tight late) — this may eventually warrant a separate `PositionEstimator` instantiation/config for PPP mode, but this is a tuning question to revisit empirically after Phase 2 ships, not a required day-one code change.

## Phase 2a: Verification Gate Results

**Run by Pesho manually via SSH against live station BS-Aheloy** (not executed by the assistant — this dev environment cannot reach the station or execute its aarch64 binaries). Raw findings as reported:

### Check 1 — `rnx2rtkp -p 8` support: **PASS**

Binary located: `/usr/local/bin/rnx2rtkp` (`file`: ELF 64-bit LSB pie executable, ARM aarch64, for GNU/Linux 3.7.0, not stripped).

Help output (relevant excerpt):
```
 -p mode   mode (0:single,1:dgps,2:kinematic,3:static,4:static-start,
                 5:moving-base,6:fixed,7:ppp-kinematic,8:ppp-static,9:ppp-fixed) [2]
```

Dry-run: `rnx2rtkp -p 8 -m 15 -f 2 -o /tmp/fake_out.pos /tmp/fake.obs /tmp/fake.nav /tmp/fake.sp3 /tmp/fake.clk /tmp/fake.atx` with empty placeholder files → exit code 0, no "unknown option" error. Flag is parsed correctly; no output file was produced because input files were empty/invalid, which is the expected result for placeholder content.

**`-p 8` (ppp-static) is natively supported by the installed binary.**

### Check 2 — ZED-F9P RINEX L1+L2 dual-frequency data: **PASS**

Real file inspected: `/home/peshovp/RPI-BS/geomaxima_survey/rinex/2026-08-03_05-28-52_GNSS-1.obs`, RINEX version 3.04.

Header `SYS / # / OBS TYPES`:
```
G    4 C1C L1C C2X L2X
R    4 C1C L1C C2C L2C
E    4 C1X L1X C7X L7X
C    4 C2I L2I C7I L7I
```

Real data record example (non-zero L2 confirmed):
```
G23  24738385.470   130001139.9371   24738385.776   101299495.616
```
(fields: C1, L1 phase, C2, L2 phase — all four populated with real numbers)

MSM7 config cross-checked against `addons/features/gnss_config/zedf9p_config.py`:
```python
'MSGOUT_RTCM_3X_TYPE1077_UART1': 0x209102cc,
'MSGOUT_RTCM_3X_TYPE1087_UART1': 0x209102d1,
'MSGOUT_RTCM_3X_TYPE1097_UART1': 0x20910318,
```

**Genuine L1+L2 dual-frequency RINEX 3.04 data confirmed — sufficient for PPP processing.** This resolves the "not independently verified" caveat in §2 above.

### Check 3 — Precise-product source reachability: **PARTIAL**

GPS week computed for the test run: week 2430, `WWWWD` = 24302 (2026-08-04 UTC). Final-tier reference date (21 days prior): week 2427, `WWWWD` = 24272.

**igs.ign.fr**: `curl` exit code 28 (connection timeout) on all three tier URLs tested. Consistent with a separate `ping -c 3 igs.ign.fr` → 100% packet loss. **NOT REACHABLE** from BS-Aheloy's network.

**WHU mirror** (`igs.gnsswhu.cn`, HTTP): `curl` exit code 7 (failed to connect). **NOT REACHABLE.**

**CDDIS** (`cddis.nasa.gov`):
- HEAD requests to specific legacy short-form filenames (`igu`/`igr`/`igs` + `WWWWD`): all returned HTTP 404 (server reachable, responds normally, no immediate auth error on HEAD alone).
- Directory index request (no filename), not following redirects: HTTP 302 → `https://urs.earthdata.nasa.gov/oauth/authorize?client_id=gDQnv1IO0j9O2xXdwS8KMQ&response_type=code&redirect_uri=https%3A%2F%2Fcddis.nasa.gov%2Fproxyauth&state=...`
- Real GET with redirect-following (`curl -sL`) to a specific final-tier filename (`igs24272.sp3.Z`): `HTTP_CODE:200`, but the downloaded content (10,916 bytes) was confirmed via `file` to be **"HTML document, ASCII text"** — the body was the Earthdata Login page itself (`<title>Earthdata Login</title>`), not the requested `.sp3.Z` binary. This is the exact "auth-wall page saved as a binary product" failure mode Phase 2b's design must defend against (§6 of the requirements this section implements).

**Conclusion:** CDDIS is network-reachable but requires NASA Earthdata Login for actual file content — anonymous access is not possible. The 404s on named files may *also* indicate a wrong naming convention independent of the auth wall — this was never disambiguated, since the auth wall was hit first on every attempt. **Phase 2b must independently re-verify CDDIS's actual current directory/filename convention once authenticated**, not assume the legacy short-form pattern is correct just because it 404's the same way an auth-walled request would.

### Overall Phase 2a Conclusion: **GO for Phase 2b**

Carried-forward findings:
1. `rnx2rtkp -p 8` support: **CONFIRMED PASS.**
2. ZED-F9P L1+L2 RINEX data: **CONFIRMED PASS.**
3. `igs.ign.fr` / WHU: **CONFIRMED UNREACHABLE** from station network — do not use as primary source; §5's original "IGN as primary" recommendation is **superseded** by this finding.
4. CDDIS: **CONFIRMED REACHABLE** but requires Earthdata Login. Credentials have since been registered. Phase 2b must implement authenticated access *and* independently re-verify the correct CDDIS directory/filename convention per tier.
5. Credential storage decision: store locally per-station in `settings.conf` with restrictive permissions, following the exact WireGuard `PrivateKey`/`PresharedKey` `_FIELD_MAP` convention (blank submission preserves existing value; secret fields never pre-populated in HTML).

## Phase 2b: Downloader Implementation

**Status:** code written, compile-checked, **not live-tested**. Per the task's explicit instruction, no real download was attempted against Pesho's actual Earthdata credentials in this session — that is the required next manual step before Phase 2c/2d can depend on this module.

### Files changed

- **New:** `addons/features/auto_survey/ppp_downloader.py` — `PPPDownloader` class, `compute_gps_date()`, `_validate_downloaded_product()` auth-wall guard, distinct exception types.
- **New:** `web_app/ppp_earthdata_settings.py` — `[earthdata]` section reader/writer for `settings.conf`, following the WireGuard `_FIELD_MAP` convention exactly (see below).
- **Modified:** `web_app/server.py` — two new routes, `GET`/`POST /api/auto_survey/ppp_credentials`.
- **Modified:** `web_app/templates/settings.html` — new "PPP-static / Earthdata Login" card nested inside the existing Auto Survey-In section.
- **Modified:** `web_app/static/settings.js` — load/save wiring for the new card.
- **No changes to `requirements.txt`, `install.sh`, or `perform_update.sh`** — both `requests` (already in `web_app/requirements.txt:33` and `addons/requirements.txt:8`) and `gzip` (base OS package, and confirmed via `gzip --help` semantics that GNU `gzip -d` decompresses legacy `.Z`/LZW input natively, not just `.gz`) were already available. No new dependency was introduced.

### Credential storage: confirmed following the WireGuard pattern

`ppp_earthdata_settings.py` mirrors `web_app/wireguard_settings.py` structure-for-structure: the same `_FIELD_MAP` tuple-of-tuples convention, the same "positional list" return shape (`[{"source_section": ...}, {key: val}, ...]`), and — critically — the same secret-preservation fix already validated for WireGuard's `private_key`/`preshared_key`: `write_earthdata_settings()` only overwrites the `password` field when a non-empty value is submitted; a blank submission falls back to the existing on-disk value via the same `existing_values.get(key, "")` merge pattern `write_wireguard_config()` uses. The HTML password field is never pre-populated (`ppp-earthdata-password` has no `value=` attribute at all, matching `private_key`/`preshared_key`'s `value=""`), and the JS layer only ever asks the server for a `has_password` boolean, never the real password (mirrors the WireGuard settings page never echoing the real key).

**One deliberate deviation from the WireGuard pattern, flagged explicitly:** WireGuard's writer `os.chmod()`s `wg0.conf` to `0o600` after every write, since that file exists solely to hold WireGuard secrets. `settings.conf` is a much more widely shared file (written non-atomically elsewhere by `RTKBaseConfigManager` and atomically by `rtkbase_config.py`'s `update_position()`, and already holds other plaintext secrets — `svr_pwd_a`, `svr_pwd_b`, `local_ntripc_pwd` — with no existing permission hardening). Unilaterally chmod'ing the whole file from this one write path risks breaking whatever a non-root service (e.g. `run_cast.sh`, which `source`s this file) currently expects. This was written into `write_earthdata_settings()` as an explicit comment rather than silently applied — **open question for the user:** should `settings.conf` get a permission hardening pass repo-wide (a real, separate change), or is per-write chmod from this one new module acceptable despite affecting a shared file?

### CDDIS naming convention: still NOT confirmed

Phase 2a hit the Earthdata auth wall on every attempt before any filename pattern could be validated as correct or incorrect — the 404s observed could mean "wrong tier/date," "wrong naming convention," or both simultaneously with the auth wall. `ppp_downloader.py`'s `_build_url()` targets CDDIS's documented long-filename convention (`IGS0OPSRAP_{YYYYDDD}0000_01D_15M_ORB.SP3.gz` style, adopted IGS-wide since November 2022), with `_build_legacy_url()` (the short-form `igr`/`igu`/`igs` + `WWWWD` pattern) wired in as an automatic fallback inside `fetch_products()` when the primary attempt returns 404. **Neither pattern has been exercised against an authenticated CDDIS session** — this is explicitly called out in the module's own `_KNOWN_LIMITATIONS` block and must be resolved by a real live test.

### ANTEX: confirmed static/bundled decision, not yet actioned

Per §5/§7's original recommendation, `ensure_antex()` treats the ANTEX file as a static, bundled repo asset (expected at `addons/features/auto_survey/igs20.atx`) rather than something downloaded per-survey — antenna PCO/PCV models change on a multi-year IGS-convention cycle, not per survey run. **No `.atx` file has actually been bundled yet** — `ensure_antex()` raises `PPPDownloaderError` with an explicit message and a source URL (`files.igs.org/pub/station/general/`) if the file is missing, rather than silently proceeding without antenna corrections (which would quietly reintroduce several centimeters of systematic bias — exactly the kind of accuracy loss this whole migration exists to eliminate). Adding the actual bundled file is an open action item, not part of this phase's code.

### Error handling

Five distinct exception types were implemented directly against the task's requirement: `NoCredentialsConfiguredError`, `CredentialsRejectedError` (HTTP 401/403), `ProductNotPublishedError` (HTTP 404), `NetworkUnreachableError` (connection-level failure), and `InvalidProductContentError` (the auth-wall-page-saved-as-binary failure mode). `_validate_downloaded_product()` checks both a minimum plausible file size and — more importantly — HTML/`<!doctype`-style content sniffing plus gzip/compress magic-byte verification (`\x1f\x8b` for `.gz`, `\x1f\x9d` for `.Z`) before any content is trusted, directly modeled on the exact failure Phase 2a observed (a 200 OK response body that was the Earthdata Login page). None of these exceptions are caught-and-silently-ignored anywhere in this module — per Pesho's "no fallback, no silent start" decision, a failed product fetch is designed to surface as a failed survey update once wired into `survey_controller.py` in Phase 2d, not silently degrade to SPP or proceed without precise products.

### Interface for Phase 2d

`PPPDownloader.__init__(products_dir, credentials=None, session=None, settings_file=None)` accepts injectable `credentials`/`session` for testability, defaulting to reading from `settings.conf` via `ppp_earthdata_settings.py` and constructing a real `requests.Session()` only when actually needed (lazy, in `_ensure_session()`). `fetch_products(tier, survey_start_time) -> Dict[str, Path]` matches the signature requested in this task (`download_precise_products`, functionally identical — kept as `fetch_products` to match the name already used in this design doc's §5/§7, no functional difference).

### Open questions carried forward to Phase 2c

1. **Live Earthdata auth test — required before anything else.** Pesho to run a real `PPPDownloader(...).fetch_products("rapid", <recent datetime>)` call on-station with real credentials, and report: does the Basic-Auth-on-redirect flow actually work end-to-end, or does CDDIS require a different mechanism (e.g. a pre-established `.netrc`-equivalent session/token flow that Basic Auth alone doesn't satisfy)?
2. **Correct CDDIS filename convention** — confirm via the live test above whether the long-form or legacy short-form URL (or neither, if both patterns are wrong) actually resolves.
3. **`settings.conf` permission hardening** — resolve the chmod question flagged above before this ships broadly.
4. **Bundle an actual `igs20.atx` file** into the repo.

## 7. Phased implementation plan

Each phase is scoped to be independently `git diff`-reviewable and independently testable, per this project's established discipline (small, verifiable, non-big-bang commits).

**Phase 2a — Verification only, no new code.**
Confirm on real Pi hardware (not this dev machine, which cannot execute the aarch64 `rnx2rtkp` binary): (1) `rnx2rtkp --help` or equivalent output actually lists `-p 8` and precise-product file args as supported — some minimal RTKLIB builds omit certain pos-modes; (2) a real captured raw log run through the existing `convbin` pipeline produces a RINEX obs file whose header actually lists L2 (or L5) observation types for at least GPS, confirming dual-frequency data is genuinely present, not just theoretically available from the receiver. **Gate: do not proceed to 2b until both are confirmed with real command output, not assumed from datasheets.**

**Phase 2b — `ppp_downloader.py` (new file only).**
Implement `PPPDownloader` as designed in §5, with unit-testable date→filename logic (GPS week/day-of-year math has no external dependency and is fully testable offline) and network-fetch logic behind a mockable interface. Ship with a small standalone CLI/script entrypoint (`tools/fetch_ppp_products.py` or similar) so the download logic can be exercised and verified manually against real IGN/WHU URLs before any survey code depends on it. No changes to `addons/features/auto_survey/` in this phase.

**Phase 2c — `ppp_processor.py` + `ppp_static_survey.conf` (new files only).**
Implement `PPPProcessor` per §4, using product files fetched by Phase 2b's downloader (called manually/directly in this phase, not yet wired into `SurveyController`). Test it standalone against a real RINEX file + downloaded SP3/CLK/ATX from Phase 2b, comparing the resulting `.pos` file's reported std devs against the equivalent SPP run on the same data. No changes to `survey_controller.py` in this phase.

**Phase 2d — `survey_controller.py` integration.**
The actual swap: import `PPPProcessor`, instantiate it with a resolved products directory (calling `PPPDownloader.fetch_products()` at the appropriate point in `_perform_update()`/`_perform_interim_update()`), adjust the `update_schedule` for PPP's longer convergence characteristics per §3 point 4, and add a "still converging" quality indicator to the state/status payload consumed by the UI. This is the only phase that touches the existing, working `survey_controller.py` — keep it as small a diff as possible (ideally: swap the `self.spp` assignment + the schedule constant + one new status field, nothing else structural).

**Phase 2e — Optional final-products reprocessing (separate, later, opt-in).**
A scheduled/manual re-run using final products ~14-18 days post-survey, per §5. Requires also changing `_stop_file_logging()`/finalization behavior to retain raw/RINEX data instead of the current cleanup — this is a real behavior change to existing code and should be its own reviewed, separately-flaggable phase, not bundled with 2d.

## 8. Risks

- **Internet dependency (new, breaking change to an offline-capable feature):** today, Auto Survey-In works with zero network access — SPP only needs the receiver's own broadcast ephemeris, already in the RINEX nav file. PPP-static as designed here requires reaching IGN/WHU/CDDIS for every survey. **If the base station is deployed somewhere without reliable internet, this feature becomes unusable in PPP mode.** Recommendation: keep `SPPProcessor` available as an explicit fallback mode (user-selectable or automatic-on-download-failure), not a wholesale replacement — this should be a design decision confirmed with the user before Phase 2d, not assumed.
- **Processing time increase:** PPP-static convergence + reprocessing the full accumulated dataset on every interim update (matching the existing pattern at line 514, which reprocesses from scratch each call, not incrementally) means each interim update's `rnx2rtkp` run gets progressively longer as the survey proceeds and the RINEX file grows, and PPP's per-epoch computation is more expensive than SPP's regardless. On resource-constrained hardware (this repo explicitly targets Raspberry Pi class devices, confirmed in `find_rtklib_tool()`'s `armv7l`/`aarch64` search paths), this could mean multi-minute processing runs by hour 20+ of a survey, potentially colliding with the existing `timeout=600` (10 minute) hard timeout in the processor call, or straining a Pi 3B-class device's limited CPU (referenced in earlier session commit-message context around watchdog CPU-load rationale, not independently re-verified here).
- **Disk space for precise products:** SP3+CLK for one day is typically a few hundred KB to low single-digit MB compressed; over a 24-48h survey with hourly re-fetches this is not large in absolute terms, but combined with retained raw/RINEX data for Phase 2e reprocessing (§5, §7), disk usage on a Pi's SD card could become non-trivial over many repeated surveys if old data/products are never pruned. No pruning/retention policy is proposed in this design — flagged as an open question for Phase 2d/2e implementation, not resolved here.
- **RTKLIB build/version constraint — NOT independently verified this session.** I could not execute the actual `tools/bin/RTKLIB-2.5.0/aarch64/rnx2rtkp` binary present in this repo (Windows dev host, ARM binary) to confirm it was built with `-p 8`/precise-ephemeris support compiled in. This is the single most important unverified assumption in this entire design and is why Phase 2a is a hard, non-skippable gate before any implementation work begins.
- **ANTEX file licensing/bundling:** IGS ANTEX files are freely redistributable, but bundling one in-repo needs a one-time check of current file size and license terms (should be trivial — IGS publishes these openly — but not verified in this session; flagged for Phase 2c).
