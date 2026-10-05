# Autosurvey / PRIDE-PPPAR pipeline fix plan - status handoff

Last updated: 2026-10-05, after Part 6b (`960f130`). This file exists so
a fresh session (after a context reset/new conversation) can resume work
without re-deriving the plan, the standing rules, or what's already done.

## Standing rules (apply to every part below, no exceptions found so far)

1. **Diff first, wait for explicit approval, before every commit.** Not
   a one-off - established early in this effort and never relaxed.
2. **Commit directly to `main`.** No feature branches for this effort.
3. **Station names never appear in commit messages** (generic placeholders
   only - e.g. "a test station", not "BS-Topolchane"/"BS-Aheloy").
4. **After every push, report "committed and pushed" with the
   `git ls-remote origin refs/heads/main` hash** - "landed on main" alone
   is explicitly not acceptable; an unpushed commit never reaches a
   station.
5. **Attribution line** on every commit: `Co-Authored-By: Claude Sonnet 5
   <noreply@anthropic.com>` (matches whichever model is actually active -
   check the session's own system reminder at commit time; this has
   varied across sessions).
6. **No hard-coded DNS** - stations must use only the network's own
   resolvers (DHCP-provided), never a hardcoded public resolver, never
   DNS through the WireGuard tunnel (`2b01198`, pre-dates this doc but is
   a standing constraint any future DNS-adjacent change must respect).
7. **An OTA update, by itself, must never change what any station is
   currently broadcasting.** Every place that writes `position=`/calls
   `update_position()` must only ever use lat/lon/height values already
   computed and persisted by an actual survey run - never recomputed as
   a side effect of code changing. Verified explicitly for Part 6a (ARP
   handling) - re-verify this property any time `_apply_geodetic_position()`
   or its callers change.
8. **The 0.01m ECEF invariant
   (`bgs2005_transformer.py`'s `verify_rtcm_broadcast_ecef()`,
   `RTCM_ECEF_SANITY_THRESHOLD_M`) is load-bearing and must never be
   loosened without an explicit, reasoned instruction to do so.** It is a
   write-precision round-trip check (same point, same transform, twice),
   NOT a comparison against the ~5cm АГКК/BGSTrans residual (a completely
   different, independent comparison - see Part 10 below). Extending it
   to cover a new step in the broadcast chain (e.g. a future antenna/ARP
   correction) is preferred over leaving that step unchecked - but Part 6a
   found that the right design is often "don't insert a new step into the
   chain at all" rather than "extend the check through it" - see Part 6a's
   entry below.
9. **Never fabricate a measured/calibrated value as a default.** Height-
   system fields, ANTEX calibration status, ARP offsets, etc. all default
   to an explicit "unavailable"/"uncalibrated"/zero-with-a-reason state,
   never a silently-assumed real value.

## Where real data (fixtures, exposure checks) came from

- The only REAL PPP-AR run fixture available so far is a GPS-only
  (E15/C26 unusable on an F9P at the time) run from doy 272 on one
  station, recovered from a slot directory `76ccadd` moved out of the git
  checkout (still intact on disk, not deleted). Used for Part 5's
  cst_*/amb_*/pos_* parsing tests.
- Part 9's multi-constellation (QZSS-present) test fixture is henceforth
  SYNTHETIC - no station has yet produced a real multi-GNSS AR run. Part 5's
  own INFO-level stdout logging exists specifically so the next real
  multi-GNSS run can be captured and used to replace that fixture - see
  `test_part9_fix_rate_synthetic.py`'s own FIXTURE NOTE/TODO.
- The ArduSimple AS-ANT3BCAL01 NGS calibration (Part 6b) was fetched live
  from `https://geodesy.noaa.gov/ANTCAL/LoadFile?file=AS-ANT3BCAL01_NONE.atx`
  during that session (WebFetch/WebSearch tools were available) -
  provenance recorded in `addons/geomaxima_antex/custom.atx`'s own header.

## Part status

| Part | Description | Status | Commit(s) |
|---|---|---|---|
| 0-4 | (pre-dates this doc's creation; see git log before `f751930` for full history) | done | multiple, see `git log --oneline` |
| 4b | Raw-log rotation handling for PPP-AR interim slots (survey-window-spanning files, zipped-archive extraction) | done | `ca1dfc3` |
| Item 2 pt.2 | File-logging crash-restart with backoff/incident threshold | done | `b500e9b` |
| Item 2 follow-up | Stale `file_service_owned` + one-owner rule (user-enabled service never owned/stopped) | done | `d8e817a` |
| Height regression | RTCM 1005/1006 broadcast height reverted to always-ellipsoidal (fixing a reintroduced `52028a3` regression); 0.01m ECEF invariant added; `tools/check_rtcm_height.sh` exposure-check script | done | `027ff87` |
| 5 | PPP-AR per-attempt quality evidence: product_tier, processed-window-vs-obs-span (<50% warning), AMB resolvable-sat/fixing T/W/N per constellation, frequency combination (Part 1) - persisted per-attempt (not just on success), UI table | done | `2b4b970` |
| Retention | Isolated+pruned rinex_dir for rnx2rtkp path (rule 1); size logging on prune (rule 3); protected-slot-dir marker so an applied result's evidence is never pruned (condition 1); legacy loose-file cleanup, age-gated (condition 2) | done | `8a1d83d` |
| 8 | PPP-AR retry attempts 3->5 (delay unchanged, 120s), logs which attempt succeeded; vendored `pdp3.sh` bdspride curl branch: `--max-time` 60->180s + `--disable-epsv` (NOT yet confirmed live - reasoned by analogy); confirmed OTA's existing hash-check (`perform_update.sh`) auto-rebuilds `pdp3` when vendored source changes | done | `c11e131` |
| 9 | Fixed a confirmed-from-source multi-constellation bug: `_parse_fix_rate_line()` now takes the LAST "Wide/Narrow-lane FR(ind)" match (QZSS prints an identically-prefixed line before the true combined aggregate); split `PPP_AR_MIN_FIX_RATE_PERCENT` into separate WL/NL constants (still 90.0); cst_* T/W/N reconciliation with `fix_rate_mismatch` flag; per-call logging | done | `c28e9d4` |
| 6a | Antenna/receiver info + ARP height into RINEX header for both PPP backends; PPP/PPP-AR ALWAYS processed at the antenna's own ARP (never the marker) - `ant1-antdel*=0` for rnx2rtkp, `convbin -hd 0/0/0` for PRIDE-PPPAR; marker position recovered ONLY for reports via `arp_to_marker()` (exact ECEF/ENU round-trip) + its own `verify_arp_to_marker_offset()` invariant; `antenna_calibrated` DERIVED from ANTEX lookup (not a manual key); new `antenna_arp_height_m/east_m/north_m` settings.conf keys (OTA-safe, default 0.0); UI reference-point report + uncalibrated-antenna note | done | `a487b3a` |
| 6b | Custom ANTEX support: vendored ArduSimple AS-ANT3BCAL01 NGS calibration (`addons/geomaxima_antex/custom.atx`), merged into igs20.atx for rnx2rtkp (hash-cached) and injected per-run into pdp3's own freshly-downloaded ANTEX via a `GEOMAXIMA_CUSTOM_ANTEX` env var + a local `pdp3.sh` patch (PRIDE-PPPAR has no persistent ANTEX file of its own). **Found during review, not cosmetic**: PRIDE-PPPAR's `rdatx.f90` has NO cross-GNSS frequency substitution at all (confirmed file/line) - a 2-frequency (G01/G02-only) ANTEX entry would silently give zero PCO/PCV to every other constellation Part 1 could select. Fixed by implementing the documented historical IGS substitution convention ourselves (GPS L1 for upper-band, GPS L2 for lower-band), logged per-band every run, carried into the Part 5 record and UI | done | `960f130` |
| 10 | READ-ONLY report on the BGS2005 transformation (~5cm residual vs АГКК BGSTrans, epoch handling) | **next** | - |
| 11a | SOFI validation harness (BKG IGS/obs path, `_S_`/`_R_` naming, `crx2rnx` from official RNXCMP source) | pending | - |
| 7 | Frozen final window, "finalizing - waiting for product coverage" state, retry until accepted, remove the 540min time-based watchdog, 24h heartbeat + open-ended UI state, preserve final obs/slot | pending | - |
| 11b | Differential PPP vs SOFI - design report only, no code | pending | - |

## Open questions / follow-ups not yet actioned

- **Retention rule 2** (prune by survey boundary, not just by count) -
  proposed, approved for rules 1+3 only so far; rule 2 explicitly
  deferred to "after the next survey" (per the user's own instruction) -
  not yet implemented.
- **Part 8's bdspride curl patch** (`--max-time` 180s, `--disable-epsv`)
  is NOT yet confirmed live on any station - reasoned by analogy to the
  already-confirmed-live `igs.gnsswhu.cn` fix, not independently tested.
  Revisit once a station actually exercises that code path again.
- **`ConfigManager.update_position()`** (`config_manager.py`) is DEAD
  CODE with a stale/misleading docstring ("Orthometric height (MSL)") -
  confirmed never called anywhere in the live pipeline, so it does not
  affect the RTCM broadcast invariant, but should be fixed or removed if
  anyone ever wires it up.
- **`geomaxima_ppp/` (ANTEX + precise-product cache) has NOT been moved
  out of the git checkout** the way `geomaxima_survey/`/`geomaxima_geoid/`
  were (`76ccadd`) - explicitly deferred (`survey_controller.py`'s own
  NOTE comment), tracked separately, not yet scheduled.
- **Orange Pi branch (`feature/armbian-opi4pro-support`) has NOT been
  updated with `main`'s work** - as of this doc, its tip (`68c61fe`) is
  itself an ancestor of `main`'s much earlier history (before `f751930`);
  it has received none of the DNS migration (`2b01198`) or anything from
  this session (`f751930` through `960f130`, 21 commits). Needs an
  explicit merge/rebase decision before that branch is usable again.
- **Part 9's QZSS fixture is synthetic** - replace with real data once a
  station produces a genuine multi-GNSS (QZSS-containing) AR run; the
  INFO-level stdout logging needed to capture it already exists.

## Remaining task order (as last confirmed by the user)

Part 10 (read-only report) -> Part 11a -> Part 7 -> Part 11b.

## How to resume

1. Read this file.
2. Confirm the three ls-remote hashes below still match
   `git ls-remote origin refs/heads/main` /
   `refs/heads/feature/armbian-opi4pro-support` (if they don't, something
   happened between this doc's last update and now - investigate before
   assuming the table above is still accurate).
3. Pick up at Part 10, diff-first as always.

**Hashes at the time this file was written:**
- `main`: `960f13048def7add890e7fcee646202e5b14513b`
- `feature/armbian-opi4pro-support`: `68c61feca0ae7395d750d971e88da6e483299855`
