# Auto Survey

Automatic determination of the base-station coordinate with **PRIDE-PPPAR**
(`pdp3`, PPP with ambiguity resolution), applied to RTKBase as the broadcast
position (RTCM 1005/1006). PRIDE-PPPAR is the only positioning backend; there
is no SPP/rnx2rtkp fallback.

Design, semantics and known limitations of the runner service:
[`docs/survey_service.md`](../../../docs/survey_service.md).
Running status and hand-off notes: [`docs/autosurvey_status.md`](../../../docs/autosurvey_status.md).

## How a survey runs

1. **Start.** The web app (`/api/auto_survey/start`, body `{"target_hours": N}`)
   submits a request; the survey runs in its own systemd service
   `geomaxima_survey.service`. The survey owns the File service
   (`str2str_file`): it starts at survey start and stops when the survey ends
   for any reason.
2. **Collecting.** Raw logs are collected for `target_hours`. The window is
   frozen at the survey start; only data inside it is used.
3. **Finalizing.** When the window is over the File service stops and the state
   becomes `finalizing`. The runner waits until the precise products for the
   window (RAP/FIN ERP + orbit) are published (`product_availability.py`),
   then converts the raw logs to one continuous RINEX (convbin, 30 s) and runs
   `pdp3`. A failure is classified (`ppp_ar_failure.py`) and retried
   indefinitely with a reason, next-retry time and heartbeat in the state.
4. **Applying.** A result that passes the fix-rate gate (90 % WL and 90 % NL)
   is transformed ITRF2020 -> ETRF2000 -> BGS2005 (epoch 2005.0), checked
   against the ECEF invariant, written to `settings.conf` (ellipsoidal height
   for the broadcast) and the services are restarted.

## Modules

| File | Role |
|---|---|
| `survey_controller.py` | Survey lifecycle: collecting, finalizing, retry, apply (`_apply_geodetic_position`), reconcile |
| `survey_runner.py` / `survey_requests.py` | Service entry point and the file request protocol (web -> runner) |
| `pride_pppar_processor.py` | pdp3 invocation, `pos`/`amb`/`cst` parsing, frequency selection, fix rates |
| `product_availability.py` | Checks whether the precise products of a day are published |
| `rinex_converter.py` | convbin wrapper (RINEX 3.04, segment merge, `-ti 30`) |
| `antex_support.py` | ANTEX lookup, custom/merged ANTEX, band calibration classification |
| `bgs2005_transformer.py` | ITRF2020 -> ETRF2000 -> BGS2005 with epoch reduction |
| `geoid_corrector.py` | Geoid model for the displayed normal height |
| `ppp_ar_failure.py` | Failure classification and messages |
| `process_group.py` | Runs pdp3/convbin in their own process group with a hard timeout |
| `rtkbase_config.py` | Reads/writes RTKBase `settings.conf` (position, receiver, antenna) |
| `state_manager.py` | Persistent survey state (`/var/lib/rtkbase/survey_state.json`) |

## Endpoints (web app)

- `GET /api/auto_survey/status` - state, progress, phase, final-retry indicators
- `POST /api/auto_survey/start` - body `{"target_hours": N}`
- `POST /api/auto_survey/stop`, `POST /api/auto_survey/reset`
- `GET /api/auto_survey/geoid`, `POST /api/auto_survey/geoid/upload`

## Rules

- A newly applied survey is the only thing that may change the broadcast
  position; an OTA never does.
- Never run an OTA during a `running` survey.
- The broadcast height is ellipsoidal; the BGR2005 normal height is for display
  and reports only.
