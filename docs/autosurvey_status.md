# Autosurvey / PRIDE-PPPAR pipeline fix plan - status handoff

Last updated: 2026-10-13, after a live OTA verification found that the
archive/OTA incident fixes (`329cd8b`, `72584ad`) hadn't actually
applied (see below) - fixed in the next commit after this doc update.
This file exists so a fresh session (after a context reset/new
conversation) can resume work without re-deriving the plan, the
standing rules, or what's already done.

## 2026-10-05/06/07/10 data-loss incident - summary

A test station lost every raw archive (several zips spanning Sep 23 -
Oct 1) in one run of `archive_and_clean.sh` at 04:00 on 2026-10-05, and
separately had `str2str_file.service` (raw GNSS logging) stopped for
4+ days starting 2026-10-01 06:16.

**Confirmed, by direct testing against the real code - not just
inspection:**
- `archive_and_clean.sh` was unsafe by construction: it `source`d the
  entire settings.conf as shell code with zero validation, then used
  the result directly in a destructive `find -delete`. A literal `"0"`
  or `"00"` for `archive_rotate` genuinely deletes every archive
  regardless of real age; a leading zero like `"08"` CRASHED the age
  check entirely (bash misreads a leading-zero numeral as invalid
  octal in both `(( ))` and `[[ -lt ]]` contexts).
- `audit.log` writes from `archive_and_clean.sh` were silently
  swallowed by TWO independent causes: wrong file ownership
  (root:root 0644, unwritable by the service's own non-root user) AND
  the unit's own `ProtectSystem=strict` sandbox (no `ReadWritePaths`
  grant for a path outside the script's own directory). Both fixed;
  a stderr+`logger` fallback now also exists so a future write failure
  is never silent either way.
- The journal itself was volatile (no `Storage=persistent`), which is
  why pre-incident logs (Oct 1-4) were unrecoverable during the
  investigation - fixed via `tools/install.sh`'s
  `install_journald_retention()`.
- File-service **STOPPED**: confirmed - `d8e817a` (2026-10-01 18:34), a
  stale `file_service_owned` one-way latch, plain `systemctl stop`
  (`survey_controller.py:625`, never `ServiceController.stop()`,
  confirmed by reading the call site directly).
- File-service **DISABLED**: cause unknown - no code path found
  anywhere in the repo (current HEAD or `git log
  -S"disable"`/`-S"DisableUnitFiles"` history since before 2026-09-15)
  that disables `str2str_file.service` as a side effect of Autosurvey,
  Watchdog, or either OTA path. The only two real
  `ServiceController.stop()` (disables-and-stops) call sites in the
  whole repo are the UI's own intentional on/off toggle
  (`switchService()` - correct to disable) and `configure_receiver()`
  (a real temporary-stop bug, now fixed via a new `stop_temporarily()`
  method) - but `configure_receiver()` only ever touches
  `str2str_tcp.service`, never `str2str_file`, so it cannot be this
  incident's mechanism. **Operator follow-up (2026-10-13): unknown - he
  may have toggled it off in the UI or deleted files manually, but does
  not remember which, and no audit trail existed for either action at
  the time (closed going forward - see below).**
- Separately corrected: commit `909a021` (2026-09-24) claims in its own
  message to add `KillMode=process` to `unit/rtkbase_web.service` -
  its diff shows only an explanatory comment was added, never the
  actual directive. Not fixed by adding it now (would orphan
  str2str/rtkrcv/PRIDE-PPPAR children on every future web restart);
  fixed instead by launching both OTA paths via `systemd-run --collect`
  outside that service's cgroup entirely, which makes the missing
  directive moot for this specific class of bug.

**Full hardening landed in two commits** (`329cd8b`, `72584ad`) -
explicit key parsing/validation, audit-log access + fallback, journald
persistence, server-side settings validation (rejecting leading zeros,
using `[0-9]` never `\d`), `LogManager` path-traversal fix, a Watchdog
raw-data-freshness check, `systemd-run --no-block` OTA launchers, a
pre-OTA service-state snapshot (run_id + freshness matched, covers
`.timer` units, raw state strings not booleans) restored in BOTH OTA
scripts before their final web-service restart, and a visible
status/settings page warning when raw logging is off and unowned. 121
tests across 11 files, all run and passing on real Linux (WSL Ubuntu
24.04) this session - not assumed correct from inspection or from a
Windows/Git-Bash run alone.

### 2026-10-13: live OTA verification found the fix itself didn't apply

A real OTA to commit `fccc038` on a test station confirmed the broadcast
position/settings/services were all correctly preserved, but THREE of
the just-landed fixes (audit-log-access, journald-retention, the
service-state restore) had NOT been applied at all.

**Root cause, confirmed by reading the code**:
`addons/tools/perform_update.sh` makes a private self-copy of itself to
`/tmp` BEFORE its own `git reset --hard` (specifically so that reset
replacing the on-disk file mid-run can't corrupt the running script),
and `update_controller.py`'s `perform_update()` resolves and launches
this script BEFORE any pull/reset runs. The process that actually
executes an OTA is therefore always whichever `perform_update.sh`
version was already on disk at the START of the update - inlining
post-update steps into that same script (as the previous commit did)
can **never** see its own post-reset code, no matter how the script is
edited, because the running copy was made before the edit ever landed.

**Fix**: the post-update steps now live in a separate script,
`addons/tools/post_update.sh`, which `perform_update.sh` hands off to
via `cat tools/post_update.sh | bash -s -- ...` **after** its own git
reset has already landed the new tree - always reading the file fresh
from disk at that point, never from the pre-reset self-copy. Also
added: a startup self-heal in `web_app/server.py` (root, every
`rtkbase_web.service` start) that idempotently fixes audit.log
ownership/mode and installs the journald drop-in if missing, covering
any station updated by an older launcher regardless of OTA history;
`settings.conf` backups moved from inside the git working tree
(`<rtkbase_path>/settings_conf_backups/`, fragile against a future
`git clean -fdx`/re-clone) to `/var/lib/rtkbase/settings_backups`, the
same location every other piece of this project's runtime state
already lives in, with one-time migration of any existing backups; and
`switchService()` (the UI's service on/off toggle - the only confirmed
code path that disables a unit) now logs an audit event with the
before-state, requested action, success/failure, and after-state for
every start/stop, closing the audit gap that made the File-service
"disabled" question unanswerable in the first place.

22 new tests (143 total across 14 files), all run and passing on real
Linux (WSL Ubuntu 24.04). **The next OTA is the real test of the new
post-update hand-off path** - this round's fix could only be verified
by direct code reading and simulation in this sandbox (no real
`systemd`/root OTA environment available here), not by an actual live
OTA run.

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
| 10 | READ-ONLY report on the BGS2005 transformation (~5cm residual vs АГКК BGSTrans, epoch handling) | done | `311bd59` |
| 10b | BGS2005 corrected to ETRF2000 (was ETRF2014) + epoch-2005.0 reduction (Инструкция № РД-02-20-12/2012, Чл.20+Прил.6); EUREF TN1 Table 4 direct ITRF2020->ETRF2000 Helmert step; velocity source: SOFI's own EPN-derived ETRF2000 velocity (0.52mm/yr) as a **PROVISIONAL PROXY for every station** - flagged in every result (`coordinate_provisional: true`); all 3 chain stages kept/labeled in result+UI | done | `f8b7914` |
| Archive/OTA incident | Data-loss incident hardening - see summary above | done | `329cd8b`, `72584ad` |
| 11a | SOFI validation harness (BKG IGS/obs path, `_S_`/`_R_` naming, `crx2rnx` from official RNXCMP source) - **now explicitly validates the Part 10b chain against SOFI's own official EPN ETRF2000@2005.0 coordinate**, the 5mm/10mm acceptance test (Чл.7, Инструкция № РД-02-20-25/2011) | pending | - |
| 7 | Frozen final window, "finalizing - waiting for product coverage" state, retry until accepted, remove the 540min time-based watchdog, 24h heartbeat + open-ended UI state, preserve final obs/slot | pending | - |
| 11b | Differential PPP vs SOFI - design report only, no code | pending | - |

## Open questions / follow-ups not yet actioned

- **Station-specific ETRF2000 velocity (Part 10b follow-up, not yet
  started)** - Part 10b's epoch-2005.0 reduction uses SOFI's own EPN
  velocity as a proxy for EVERY station, flagged provisional in every
  result. Planned fix: interpolate a station-specific velocity from the
  EPN densification (EPND) velocity field or a published Bulgarian
  intraplate model, vendored with provenance, SOFI only as fallback
  when no closer source is available. This is the single highest-
  priority open item for compliance accuracy (potential 4-6cm error
  for a station whose true velocity differs meaningfully from SOFI's).
- **File-service "disabled" root cause - CLOSED as "cause unknown",
  gap fixed going forward.** The "stopped" half is fully confirmed
  (`d8e817a`); the operator confirmed (2026-10-13) he does not remember
  whether he toggled it off in the UI or deleted files manually, and no
  audit trail existed for either action at the time. `switchService()`
  now logs a full before/requested/success/after audit event on every
  UI toggle, so this specific ambiguity cannot recur.
- **The next OTA is the real test of the post_update.sh hand-off fix**
  (see the 2026-10-13 section above) - this sandbox has no real
  systemd/root OTA environment, so the fix was verified by code reading
  and simulation only, not by an actual live update. Confirm on the
  next real OTA: audit.log ownership (root:\<user\> 0660), the journald
  drop-in (`/etc/systemd/journald.conf.d/geomaxima-retention.conf`),
  and `ota_service_state`/`post_update` events in audit.log.
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
  it has received none of the DNS migration (`2b01198`), anything from
  the Part 5-10b session (`f751930` through `f8b7914`), or the archive/
  OTA incident hardening (`329cd8b`, `72584ad`). Needs an explicit
  merge/rebase decision before that branch is usable again.
- **Part 9's QZSS fixture is synthetic** - replace with real data once a
  station produces a genuine multi-GNSS (QZSS-containing) AR run; the
  INFO-level stdout logging needed to capture it already exists.

## Remaining task order (as last confirmed by the user)

Station-specific ETRF2000 velocity (Part 10b follow-up) -> Part 11a ->
Part 7 -> Part 11b. The archive/OTA data-loss incident hardening,
including the 2026-10-13 post_update.sh hand-off fix, is done; the
File-service "disabled" root cause is closed as "cause unknown" (the
audit gap that made it unanswerable is fixed going forward). The next
OTA to any station should be checked against the verification list in
the 2026-10-13 section above.

## How to resume

1. Read this file.
2. Confirm the two ls-remote hashes below still match
   `git ls-remote origin refs/heads/main` /
   `refs/heads/feature/armbian-opi4pro-support` (if they don't, something
   happened between this doc's last update and now - investigate before
   assuming the table above is still accurate).
3. Pick up at the station-specific ETRF2000 velocity follow-up, or
   check whether the next OTA to a station confirms the
   post_update.sh hand-off fix (audit.log ownership, journald drop-in,
   ota_service_state/post_update audit events - see the 2026-10-13
   section above). Diff-first as always.

**Hashes at the time this file was written:**
- `main`: `abcd35a8a37edd4b525fb783370bfd7f853367fd`
- `feature/armbian-opi4pro-support`: `68c61feca0ae7395d750d971e88da6e483299855`
