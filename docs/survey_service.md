# Autosurvey as its own service (`geomaxima_survey.service`)

Status: implemented 2026-10-23 (task 6 of the Autosurvey repair). Not yet deployed to any station.

## Why

The survey used to run as a thread inside the web server (gunicorn worker).
A gunicorn WORKER TIMEOUT killed it (confirmed 2026-10-13 04:44), and every
web restart (OTA, watchdog) killed it too. A long job must outlive the web
app and resume by itself.

## Pieces

| Piece | File | Role |
|---|---|---|
| Runner | `addons/features/auto_survey/survey_runner.py` | Service entry point (`python -m addons.features.auto_survey.survey_runner`). Creates the `SurveyController` (`is_runner = True`), waits up to 300 s for `str2str_tcp.service` if a survey may resume, calls `recover_survey()` (reconcile), then serves requests every second and calls `get_status()` every 30 s (the runner is the only process that auto-applies a completed survey). |
| Requests | `addons/features/auto_survey/survey_requests.py` | File protocol under `/var/lib/rtkbase/survey_requests/` (`pending/`, `results/`, `rejected/`, mode 0700): `submit_request`, `take_next_request` (FIFO, invalid files go to `rejected/`), `write_result`, `wait_for_result`, `cancel_request`, `cleanup_stale`. All writes are atomic (temp file + `os.replace`). |
| Unit | `addons/unit/geomaxima_survey.service` | `User=root`, `Restart=on-failure`, `KillMode=control-group` (pdp3/convbin and all children die with the service), `WantedBy=multi-user.target`. Deployed by `tools/copy_unit.sh` (glob `addons/unit/*.service`). |
| Web side | `web_app/server.py` | `/api/auto_survey/start|stop|reset` call `_survey_request()`: submit a request, `systemctl start geomaxima_survey.service`, wait for the result (30 s). On timeout the request is withdrawn (504). The web controller is READ-ONLY: `get_status()` reloads the state from disk; it never resumes, starts or applies. |
| State | `addons/features/auto_survey/state_manager.py` | `save_state()` is atomic; `reload()` re-reads the file; `record_resume()` counts resumes (`last_resumed_at`, `resume_count`). |
| OTA | `tools/post_update.sh` | Enables the runner once (`enable --now`), restarts it after every update if it is active (it resumes by itself), never starts a disabled-by-hand/inactive unit. |
| Self-heal | `web_app/server.py` `_self_heal_survey_service()` | At every web start: state is running/paused but the unit is not active -> `systemctl start`. |
| Process groups | `addons/features/auto_survey/process_group.py` | pdp3 (2400 s) and convbin (300 s) run in their own process group; on timeout the whole group gets SIGTERM, then SIGKILL (no orphans). |

## Reconcile ("resumed after interruption")

On stop the runner leaves the persisted state untouched (`running` stays
`running`). On the next start `recover_survey()` resumes it: it makes sure the
File service runs again (survey-only policy), restarts the survey thread,
increments `resume_count` and writes the audit event `recovered` with
`resumed_after_interruption: true`.

## Semantics decided during the independent review (2026-10-23)

- `paused` means "stopped by the user". Only a `running` survey is resumed
  automatically (`StateManager.can_recover()`); the watchdog, the status page and
  the web self-heal also treat only `running` as an active survey.
- A resume that is not possible yet (receiver stream not up after a reboot or
  update) never fails the survey: in runner mode `recover_survey()` sets
  `recovery_pending` and the runner retries every 30 s while still serving
  requests; a Stop cancels the pending resume. A `running` state that is older
  than target + 48 h is failed with an explicit reason instead of looking alive.
- `reload()` keeps the in-memory state when the file is unparseable.

## Known limitations (not fixed, by design or deferred)

- A request is taken (file removed) before it runs: a runner crash in the middle of
  an action loses that request; the web gets a 504 and the operator retries. A
  request the web already gave up on may still execute (the web cannot cancel a
  request that was taken).
- `tools/post_update.sh` can restart the runner twice in one OTA (the generic
  unit-reload block and the survey block); harmless, the survey resumes.
- `post_update.sh` enables the unit if it is not enabled; a unit disabled by hand
  would be re-enabled by the next OTA (there is no UI to disable it).
- If an OTA ran while the old in-process survey thread was alive (forbidden by
  the "no OTA during a survey" rule), two survey loops could overlap until the
  web restart.

## Rules that still hold

- Never run an OTA during a survey (the runner restart is only a safety net).
- An OTA must not change the broadcast position; only a newly applied survey does.
- The 540-minute watchdog is still there (removed by Part 7, not by this change).

## Read-only checks on a station (after the OTA)

```
systemctl is-enabled geomaxima_survey.service ; systemctl is-active geomaxima_survey.service
systemctl show -p NeedDaemonReload --value geomaxima_survey.service      # expect: no
ls -la /var/lib/rtkbase/survey_requests/                                  # pending/ should be empty
grep -E 'survey_service_|recovered|self_heal' /var/lib/rtkbase/audit.log | tail
```

## Final result: frozen window, infinite retry, no fatal watchdog (Part 7, 2026-10-23)

- The final PPP-AR run processes the FROZEN window [survey start, start + target hours]
  (`window_end` is derived from the persisted start time and target, so a retry hours
  later, or after a restart, uses exactly the same data; `get_data_files_since(...,
  end_time=)` and convbin `-te` enforce it).
- If the final position fails (no data, conversion, pdp3 error, product download, fix
  rate below the gate, apply failure) `_finalize_survey` retries it until it is accepted:
  every 10 min for the first 5 attempts, then hourly. Visible indicators in the status JSON:
  `final_attempts`, `final_last_reason`, `final_next_retry_at`, and `last_heartbeat_at`
  (written at most once a minute by the survey loop and during the retry waits).
- The loop only exits early when the survey is stopped/paused/reset or the service shuts
  down; the state then stays `running`, so a restart resumes the retry.
- The 540-minute "no successful update" watchdog is no longer fatal in PPP-AR mode (an
  hourly warning instead); it still applies to the non-PPP-AR (rnx2rtkp) path.
- Not done: the Settings UI does not display the new indicators yet (they are in
  `/api/auto_survey/status`).

## No interim slots; the final result waits for the products (2026-10-24)

Owner's decision after the live finding that the precise products of a day appear ~13-19 h
after the day ends (see `docs/autosurvey_status.md`, 2026-10-24):
- In PPP-AR mode there are NO interim PPP-AR slots any more (`_compute_ppp_ar_slots()` returns `[]`).
- `product_availability.py` lists the products server (`igs.gnsswhu.cn`, anonymous FTP, one
  directory listing per year) and checks that the RAP or FIN orbit and ERP exist for EVERY UTC
  day of the frozen window. Errors mean "unknown" (fail-open).
- `_finalize_survey` loop: while the products are missing it only polls every 10 min
  (`final_last_reason` = "waiting for precise products to be published: 2026 DOY 296: ERP, ...",
  `final_next_retry_at`, heartbeat); as soon as they exist it runs pdp3, applies the position
  through the normal path (BGS2005, ECEF invariant, `settings.conf`, service restart) and
  completes the survey. A real pdp3 attempt is still made at least every 6 h regardless of the
  listing (safety net against a wrong file-name assumption).
- Expected latency of a survey result: ~13-19 h after the end of the last UTC day of the window.

## The `finalizing` state (2026-10-24)

When the survey duration is over, data collection STOPS: `_finalize_survey` freezes the
window, moves the survey to the new state `finalizing` (`StateManager.begin_finalizing()`) and
stops the File service. `finalizing` is not `running` (no raw data is collected; the watchdog
does not expect raw data and the Settings page shows "Data collection finished - waiting for the
precise products / computing the final position", with the reason, the next check and the number
of computation attempts). It is resumed automatically after any restart (always recoverable, no
grace period; the File service is NOT started again for it), may be stopped by the user, and ends
in `completed` once the final position has been computed and applied (or `failed` only for
non-retryable problems of the surrounding machinery). The web self-heal restarts the runner for
`running` and `finalizing` surveys.
