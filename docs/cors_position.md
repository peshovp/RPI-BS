# CORS position (quick start position + cross-check)

Status: design agreed with Pesho on 2026-10-24. Steps 1-2 (account store, API, Settings UI) are implemented and deployed on Topolchane (commits 3b180f3, 9ee7b93). Steps 3-7 are open.
Triggered by a vendor screen (XGEO "Set Up Base Station": coordinate source GPS / CORS / Manual).

## Decisions (Pesho, 2026-10-24)

1. **PPP-AR stays the only method for the final position.** CORS never replaces it.
2. **Quick CORS position** at first start of a station: applied **automatically, but only if
   there is no broadcast position** (empty/zero `position` in settings.conf). It is a temporary
   position until the first PPP-AR survey replaces it. An existing position is never touched
   (the "OTA/anything else never changes the broadcast position" rule holds).
3. **Cross-check**: after every PPP-AR final result the CORS position is compared with it.
   Threshold **3 cm horizontal / 5 cm vertical**. Exceeding it is a **warning only** (UI +
   audit.log); it never blocks or changes the PPP-AR result.
4. **Provider independence**: the user can create **several CORS accounts**, each a rover
   account on a different network (like the vendor screen). Nothing is hardwired to one
   provider.

## Account model

Stored OUTSIDE the repo and OUTSIDE settings.conf: `/var/lib/rtkbase/cors_accounts.json`
(root, 0600, atomic writes). One record per account:

| Field | Meaning |
|---|---|
| `id`, `name` | stable id, display name (e.g. "Sofia") |
| `host`, `port`, `mountpoint` | NTRIP caster; mountpoint may be `AUTO` (sourcetable pick) |
| `username`, `password` | NTRIP credentials; **never returned by any API** (write-only, UI shows a mask) |
| `tls` | bool |
| `mode` | `vrs` (needs our approximate position as NMEA GGA) or `single_base` |
| `frame` | coordinate system of the network's coordinates: `ETRF2000@2005.0` (BGS2005, no transform), `ETRF2000@epoch`, `ITRF2020@epoch`, `WGS84-approx` |
| `epoch` | decimal year when `frame` needs one |
| `enabled`, `use_for_crosscheck`, `use_for_quick_start` | selection |

Audit: create/edit/delete/test/compute events, **without** credentials. Logs and API responses
must never contain the password or the user name together with the host.

## Computation

New package `addons/features/cors_position/` (not part of `auto_survey`):

1. Capture the CORS stream with `str2str -in ntrip://...` into a raw RTCM3 file while the
   receiver's raw log (File service) covers the same window; for `vrs` a GGA is sent
   (`str2str -p lat lon hgt -n <ms>`), the approximate position coming from the receiver's
   own PVT (never from a stale file).
2. Convert both with convbin (30 s), solve the baseline with `rnx2rtkp` (kinematic/static RTK,
   fix-and-hold) against the CORS reference coordinate from RTCM 1005/1006 (VRS: the virtual
   reference position).
3. Accept the result only with a fixed solution, enough epochs and a sane sigma; otherwise
   report why (no fix, no stream, auth failure, ...). Classified failures like `ppp_ar_failure.py`.
4. Convert the coordinate to **ETRF2000@2005.0** with the existing `bgs2005_transformer.py`
   (frame/epoch of the account), keeping the **ellipsoidal height** for the broadcast and the
   ECEF invariant (0.01 m) before anything is applied.
5. The computation runs in `geomaxima_survey.service` as a new request type (the file request
   protocol), in its own process group with a hard timeout, so a web restart or OTA cannot
   kill it. The File service ownership rule is unchanged: a quick-start run owns
   `str2str_file` for its duration and stops it afterwards (survey-only policy).

## Behaviour

- **Quick start**: runner start-up / first web start checks `position`. If empty and an account is
  marked `use_for_quick_start`, it runs the computation and applies the result through the same
  `_apply_geodetic_position` path (state, audit.log, RTCM restart). If it fails it retries with
  backoff and shows an ERROR in the UI; it never invents a position.
- **Cross-check**: at the end of `_finalize_survey` (after PPP-AR is applied) a CORS computation
  over the same window is started for each account with `use_for_crosscheck`; the result is stored
  in the survey state (`crosscheck`: account, dN, dE, dU, horizontal, vertical, verdict) and
  shown in Settings. Verdict `warning` over 3 cm / 5 cm, `ok` otherwise, `unavailable` if no
  fix. It is advisory only.

## Task split (one concern per spec)

1. `cors_accounts.py`: store, validation, masking, audit events (no network).
2. UI + API: list/create/edit/delete/test-connection (sourcetable only), password write-only.
3. Capture + RTK computation module (str2str/convbin/rnx2rtkp wrappers, classification).
4. Frame conversion to BGS2005 + ECEF invariant check.
5. Runner request type + quick start (applies only with an empty position).
6. Cross-check at survey finalization + UI/state fields + warning.
7. Live validation on Topolchane (compute-only, then cross-check against the 1 h smoke survey;
   the quick-start apply path is exercised by tests only, Topolchane already has a position).

## Open points that need real data

- Does `rnx2rtkp` (installed by `tools/install.sh`) give a reliable fix on a short window on the
  Raspberry Pi (RAM/time)? To be measured on Topolchane.
- Which networks Pesho can use for the first live test (host, mountpoint, VRS or single base,
  frame/epoch). Credentials are entered by Pesho in the UI, never in the repo or chat.
- UM980: the capture/convert path must work with its RTCM3 MSM7 log as well.

## Findings: coordinate system of the XAG (XGEO) network, 2026-10-24

First live run on Topolchane (account on the XGEO caster, mountpoint AUTO, base station
8.04 km from the rover, 179 of 180 epochs fixed, sigma N/E/U 1.1/0.9/5.0 mm).

What the vendor documents say: only "The coordinates align with the CORS service's coordinate
system". No datum, frame or epoch is named in the base station manual, the maintenance guide,
the portable base guide or the XGEO RTK platform manual. The caster distributes the data of XAG
fixed bases whose coordinates come from each base's own "coordinate source" (GPS, CORS or manual).

Hypotheses tested against independent PPP-AR solutions of the same antenna (pdp3, IGS20 =
ITRF2020 frame; 9 h session 2026-10-19 with RAP products, and a 1 h session 2026-09-24; the two
agree to 2 cm in 3D). CORS position (raw, as received) minus the PPP position propagated to the
hypothesised network epoch with the ITRF2020 velocity (SOFI, 24.3 E / 11.2 N mm/yr):

| Hypothesis | 9 h session: E / N / hor | 1 h session: E / N / hor |
|---|---|---|
| ITRF2020 at the date of the data | -2.9 / -3.8 / 4.8 cm | -2.0 / -5.7 / 6.0 cm |
| ITRF2020 @ 2020.0 | +13.6 / +3.9 / 14.1 cm | +14.3 / +1.8 / 14.5 cm |
| ITRF2020 @ 2015.0 | 27.4 cm | 27.5 cm |
| ITRF2020 @ 2025.0 | 2.3 cm | 4.4 cm |
| best-fit network epoch | 2025.22 (2.2 cm) | 2025.16 (4.3 cm) |

Sensitivity is 26.7 mm per year of epoch, so ITRF2020 @ 2020.0 would need an unexplained
14 cm error against sessions that agree to 2 cm: it is not supported. The data fit an ITRF-type
frame at a recent epoch (date of observation, within roughly +-1 year). The vertical difference
(CORS lower by 10-11 cm in both comparisons) is not a frame effect and is unexplained
(antenna phase centre, or the height of the XAG base).

An earlier inference of "ITRF2020 @ 2020.0" (1.9 cm fit) used the broadcast position of
Topolchane as reference. That reference is itself about 14 cm horizontally (N -5, E -13 cm) and
11 cm vertically away from a fresh PPP-AR position converted with our own chain, so the fit was
circular and is withdrawn. The broadcast position of Topolchane is not ground truth until a
proper 24 h PPP-AR survey replaces it.

Consequence: the account frame option "ITRF2020 at the date of observation" (`ITRF2020@date`)
exists; the observation epoch is taken from the run.
