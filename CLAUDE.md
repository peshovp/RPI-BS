# CLAUDE.md — GeoMaxima / RPI-BS

Read this whole file before doing anything in this repository.

---

## 1. Roles: who does what (NON-NEGOTIABLE)

| Role | Who | Does | Never does |
|---|---|---|---|
| **Owner / operator** | Pesho | Runs read-only commands on stations, triggers OTA from the UI, approves diffs, makes decisions | — |
| **Orchestrator / reviewer** | Claude | Plans, splits work into small tasks, writes task specs for the coder, **reviews every diff**, runs the test suite, writes read-only verification commands for stations, commits + pushes after approval | **Writes production code itself.** Claude does not edit code files. If delegation is impossible, Claude STOPS and tells Pesho. |
| **Coder** | `qwen3.8` (local, on Pesho's machine), driven through **aider** (see §6a) | Implements exactly the task spec it receives, writes the tests the spec asks for, reports what it changed | Commits, pushes, runs shell commands, touches files outside the spec, "improves" unrelated code, edits stations |

### Mandatory loop for every change
1. **Claude** writes a task spec (template in §6) and delegates it to qwen3.8.
2. **qwen3.8** implements it in the working tree. No commit.
3. **Claude** reviews the full `git diff` against the review checklist (§7). **This is mandatory, without exception.** Claude runs the full test suite on Linux.
4. If anything fails the checklist, Claude sends qwen3.8 a precise correction spec (file, line, what's wrong, what's expected) and goes back to step 3. Claude does not "just fix it" itself.
5. Claude shows Pesho: a short summary, the root cause (if a bug fix), the full diff, and the test results. **No commit without Pesho's approval.**
6. Claude commits **directly to `main`** (no feature branches), pushes, and reports
   `git ls-remote origin refs/heads/main` → the hash. Every commit is reported.
7. Pesho runs the OTA. Claude gives **read-only** verification commands. Pesho pastes the output. Claude verifies live.

Trust nothing that hasn't been verified: not qwen's report, not a test that mocks the thing under test, not a commit message. Verify against the diff, the real repo tree and live station output.

### 1a. Claude Code = orchestrator ONLY (hard rule)
- **All code is written by qwen3.8 through aider.** "Code" means every `.py`, `.sh`, `.service`/`.timer`, `.conf` template, JS/HTML/CSS and test file in the repo. Claude Code never uses Edit/Write/NotebookEdit/`sed -i`/heredocs on them, and never applies a patch by hand, even for a one-line fix.
- **What Claude may write itself:** task specs (`.aider-tasks/*.md`), `CLAUDE.md`, `docs/*.md` (e.g. `docs/autosurvey_status.md`), commit messages, reports to Pesho, read-only commands for Pesho.
- **What Claude does itself:** reading code and logs, running tests, `git diff`/`git status`/`git log`, reviewing against §7, committing and pushing (after approval).
- If aider/qwen can't do the task (fails or produces nonsense twice), Claude **stops and reports to Pesho**. It never "just fixes it". Pesho decides: another model (devstral fallback), a smaller spec, or something else.

### 1b. Agents and skills Claude Code may use
Claude uses the installed agents/skills where they fit, to save context and to get an independent view. They are helpers for **reading, searching, planning and reviewing, never for writing code**.

| Agent / skill | Use it for | Never |
|---|---|---|
| `Explore` | Broad read-only search across the repo ("where is X used", "which code paths touch File service"); results feed the task spec | — (it is read-only) |
| `Plan` | Design/approach for a larger change before it is split into small specs (e.g. the survey-as-a-service redesign) | Treat its plan as approved; Pesho approves the direction |
| `general-purpose` / `claude` | Research, log analysis, an **independent second review** of a diff that has not seen the implementation (high-stakes: OTA scripts, geodesy, survey logic) | Editing or writing repo code files. Its prompt must say "read-only, do not modify files" |
| `claude-code-guide` | Questions about Claude Code / agent features | — |
| Skills `engineering:code-review`, `engineering:debug`, `engineering:testing-strategy` | Structure for review, root-cause hunts, test design (the output goes into a spec for qwen) | Applying fixes directly |

Rules for agents:
- Every agent prompt states: **read-only, do not edit, do not commit, do not run anything on a station.** Agents have no authority to change code.
- An agent's report is input, not proof. Claude verifies its claims against the real files/diff before relying on them (same distrust as for qwen's report).
- Independent reviewer agent: used for the high-stakes diffs in addition to (never instead of) Claude's own §7 review.
- Do not spawn agents for trivial lookups; use Grep/Read directly.

---

## 2. Project

**GeoMaxima / RPI-BS** is a Bulgarian network of GNSS base stations streaming RTK corrections (RTCM3) to the GeoMaxima NTRIP caster (`ntrip.geomaxima.bg`). It is built on RTKBase plus GeoMaxima addons: Autosurvey (PPP/PPP-AR via PRIDE-PPPAR), Watchdog, OTA, DNS/WireGuard management, BGS2005 geodesy, audit log.

Solo developer: Pesho. Goal: stations good enough for **АГКК conformity** (Instruction РД-02-20-25).

### Stations
| Station | Hardware | OS | Branch | State (2026-10-20) |
|---|---|---|---|---|
| **BS-Topolchane** (dev/test) | Raspberry Pi + u-blox ZED-F9P, antenna Beitian K700 (uncalibrated) | Raspberry Pi OS (bookworm), NetworkManager | `main` | **TEST STATION, Claude has FULL control over SSH (Pesho, 2026-10-23): OTA, surveys, restarts, corrections.** OTA to `e48e389` done 2026-10-23 (position unchanged, `geomaxima_survey.service` enabled+active, first real `post_update` run verified in audit.log). Smoke survey (6 h, PPP-AR) started 16:54 UTC; replay of the 2026-10-19 data with real pdp3: WL 100 % / NL 96.7 %. Later fixes (`ee68607`, `8cb26ac`) are in `main` but NOT yet deployed (no OTA during a survey). The 2026-10-19 survey died by the 540-min watchdog (old data-selection bug); File service OFF per policy outside a survey. See `docs/autosurvey_status.md` and `docs/survey_service.md` |
| **Orange Pi 4 Pro** | Orange Pi 4 Pro | Armbian v26.11 rolling, Debian 13 trixie, kernel 6.6 vendor sun60iw2, netplan → systemd-networkd + systemd-resolved (no nmcli) | `main` (migrated 2026-10-10) | On `69487ce`, verified healthy |
| **Production (future)** | **Unicore UM980** + **ArduSimple AS-ANT3B-CAL** (calibrated) | — | `main` | Both receivers must be supported at full capability |

User on every station: `peshovp`. Repo: `/home/peshovp/RPI-BS`. `rtkbase` inside the repo is a symlink to `.` (legacy RTKBase paths).

### Important paths on stations
- `/home/peshovp/RPI-BS/settings.conf` — runtime config, **untracked**, rewritten by the web app/OTA (backed up first).
- `/home/peshovp/RPI-BS/data/` — raw GNSS logs (`*.ubx`, `*.ubx.tag`) and daily zips.
- `/var/lib/rtkbase/audit.log` — JSON-lines audit log, **root:peshovp 0660**.
- `/var/lib/rtkbase/settings_backups/` — settings.conf backups (root 0700).
- `/var/lib/rtkbase/survey_state.json` (root 0600), `/var/lib/rtkbase/survey/`, `/var/lib/rtkbase/geoid/`, `/var/lib/rtkbase/antex/`, `/var/lib/rtkbase/ota/`.
- `/etc/systemd/journald.conf.d/geomaxima-retention.conf` — persistent journal, 500M, 1 month.
- PRIDE-PPPAR: `/home/peshovp/.PRIDE_PPPAR_BIN/pdp3` (on `rtkbase_web`'s PATH via the unit's `Environment=`).

### Key code
- `addons/features/auto_survey/` — `survey_controller.py` (slots, retry, file-logging ownership, `_apply_geodetic_position` + ECEF invariant), `pride_pppar_processor.py` (frequency selection, pos/amb/cst parsing, fix-rate gate), `bgs2005_transformer.py` (ITRF2020→ETRF2000 + epoch reduction), `rinex_converter.py` (convbin), `rtkbase_config.py`.
- `addons/features/watchdog/` — `gnss_monitor.py` (raw-data freshness, File-service state), `watchdog_controller.py`.
- `addons/features/ota_update/update_controller.py` — UI OTA; launches via `systemd-run --no-block`.
- `addons/tools/perform_update.sh` — the OTA script (self-copies to /tmp before `git reset`; CRITICAL vs BEST-EFFORT steps; finally-trap guarantees restore + web restart).
- `tools/post_update.sh` — post-reset steps, read **fresh from the new tree**, always exits 0. **Path is `tools/post_update.sh`** (every deployed parent looks there).
- `tools/branch_switch.sh` — moves stale feature-branch stations to `main` (git always runs as the repo owner).
- `tools/install.sh` — flags `--journald-retention`, `--audit-log-access --user <u>`; user resolution: `--user` → settings.conf `[general] user` → `SUDO_USER`. **Never `logname`.**
- `tools/dns_setup.sh`, `addons/dns_health.py` — DNS migration and health.
- `archive_and_clean.sh` — nightly archive (rtkbase_archive.timer 04:00, `User=peshovp`, `ProtectSystem=strict`).
- `addons/ota_service_snapshot.py` — pre-OTA service-state snapshot.
- `web_app/server.py` — includes the **startup self-heal** (audit.log access, journald, settings backup migration, branch switch).
- `docs/autosurvey_status.md` — running status/hand-off doc. Keep it current after every milestone.

---

## 3. Hard rules (never break)

### Process
- **No manual or ad-hoc fixes on stations.** Everything goes: repo → review → commit `main` → push → OTA → live verification with read-only commands. No manual `git checkout`, no editing files on a station, no hand restarts as a "fix".
- Commands given to Pesho for stations are **read-only** unless explicitly agreed otherwise.
- **Never run an OTA during an Autosurvey.**
- Diff shown before every commit. Commit directly to `main`. Push. Report the `ls-remote` hash. Every commit is reported.

### Geodesy
- **An OTA must never change the currently broadcast position.** Only a newly applied survey may change it. Check `grep '^position' settings.conf` before and after every OTA.
- The broadcast position (RTCM 1005/1006) uses **ellipsoidal height**. BGR2005 normal height is for display and reports only. The end-to-end **ECEF invariant (0.01 m, `RTCM_ECEF_SANITY_THRESHOLD_M`)** guards this.
- Reference frame: **ETRF2000. BGS2005 = ETRS89/ETRF2000 at epoch 2005.0** (АГКК; Наредба 2/2010 чл.8). Epoch reduction uses velocities (РД-02-20-12 чл.20 + Прил.6).
- АГКК РД-02-20-25: чл.7 requires **5 mm horizontal / 10 mm vertical**; чл.49 requires **calibrated antennas** (the K700 cannot be certified); чл.54–56 cover conformity assessment (valid 2 years); чл.57 requires 30 s RINEX submission, and АГКК monitors time series.

### Autosurvey
- Final coordinates: **infinite retry until success**, with visible indicators (heartbeat, UI state). Per-slot retry: **5 attempts × 120 s**.
- PPP-AR fix-rate gate: **90 % WL and 90 % NL** (`PPP_AR_MIN_WL/NL_FIX_RATE_PERCENT`).
- Get the maximum out of both receivers (ZED-F9P and UM980).

### Network / DNS
- **No hardcoded DNS anywhere.** Each station uses its own network's DNS (DHCP, or a static value the user sets). DNS servers handed out by the router's DHCP are allowed, even public ones.
- **Never DNS via WireGuard. No public fallback** (`FallbackDNS=` must be empty; `90-geomaxima-fallback-dns.conf` must not exist).
- No DNS → show an **ERROR** in the UI, never a silent fallback.

### Services / data
- The OTA **preserves every service's pre-OTA enabled + active state** (both directions, including timers). The web restart is the last step. OTAs run outside the web cgroup (`systemd-run`); `KillMode` stays `control-group`.
- **Temporary stops use `ServiceController.stop_temporarily()`.** Upstream `stop()` = **disable + stop**, reserved for the UI on/off toggle.
- **The File service (`str2str_file`) is SURVEY-ONLY** (Pesho's decision, 2026-10-14 — policy, not a bug). It is **off by default** and runs only while an Autosurvey runs:
  - The survey **always owns** `str2str_file`: it starts it at survey start and stops it when the survey ends for **any** reason (success, failure, cancel, runner death detected on reconcile). No "claim only if inactive" heuristic, no raw-file-existence check. Survey state records "survey started File service at <ts>".
  - Watchdog / gnss_monitor / UI: no survey + File service off = **normal** (no warning, no incident). Survey running + File service not active, or raw file stale past the thresholds = **critical**. No survey + File service on = **warning** ("File logging running without a survey"). The raw-data freshness check applies **only while a survey runs**.
  - The UI toggle stays; switching the File service ON with no survey running asks for confirmation explaining this policy. Audit logging stays.
  - Archiving is unchanged (archives whatever raw files exist; deletion rules unchanged).
- Raw data is never auto-deleted. Only zips older than `archive_rotate` (≥ 14, no leading zeros) are. Every deletion goes to audit.log.
- Every destructive or UI action (log delete, service toggle) is audit-logged.

---

## 4. History: what was done (Sep–Oct 2026)

- **PRIDE-PPPAR 3.2.11 pipeline:** frequency selection from the obs header (F9P → `G12 R12 E17`, no BeiDou because fewer than 4 sats carry B2I; UM980 → `G12 R12 E15 C26`); correct pos/amb/cst parsing (T/W/N lines come from `cst_*`, resolvable sats from the `amb_*` header); cross-midnight sessions use a `<doy_s>-<doy_e>` dir; RTS products (WUM0MGXRTS, igs.gnsswhu.cn, ~3 h lag) vs RAP (~11–18 h latency); the RTS↔RAP difference is ~1–3 mm.
- **RTKLIB 2.5.0 convbin:** `-v 3.04`, `-tr` for RTCM3, `-f 2` removed. Antenna cross-GNSS PCO/PCV substitution (Part 6b).
- **Part 10b:** direct ITRF2020→ETRF2000 (EUREF TN1 Table 4) + epoch reduction to 2005.0 using **SOFI00BGR's EPN velocity as a provisional proxy** (`addons/geomaxima_geodesy/sofi_velocity_etrf2000.json`).
- **DNS migration** (NetworkManager + netplan + openresolv on RPi; networkd/resolved on Armbian), no hardcoded DNS.
- **Data-loss incident (2026-10-01..05)** on Topolchane: all zips plus the Oct 1 .ubx vanished; File service stopped + disabled for 4+ days unnoticed.
  - *Stopped:* **confirmed**. A stale `file_service_owned` latch in `survey_controller.py` (plain `systemctl stop`), fixed in `d8e817a`.
  - *Disabled:* **cause unknown.** No code path found; a manual UI toggle or a manual deletion by the operator cannot be ruled out (no audit trail existed then).
  - *Zip deletion on Oct 5 04:00:* **root cause unproven** (pre-OTA settings.conf unknown). The old archive script was unsafe by construction (`source`d settings.conf; `archive_rotate=0` deletes everything).
  - Hardening: validated archive script (octal-safe, bounded, zip-only, audit logged); server-side settings validation; settings backups; journald persistent; File-service UI warning + watchdog critical; raw-data freshness check; audit for log delete + service toggle; `stop_temporarily()`.
- **OTA hardening:** `systemd-run --no-block` launcher with `--working-directory`; service-state snapshot/restore; `$LINENO` in the ERR trap; critical vs best-effort split ("completed with warnings"); `post_update.sh` hand-off (the first **real** run was on the OPi at `69487ce`); `install.sh` without `logname`; startup self-heal; `.gitignore` for runtime dirs.
- **Orange Pi** migrated from `feature/armbian-opi4pro-support` to `main` through code (branch_switch + self-heal). OTA resolution now prefers `@{u}`.
- Tests: **352 pass**; 29 pre-existing failures in `loop_emmc_test.sh` (environment-dependent, not regressions). Always run on **Linux (WSL Ubuntu 24.04)**, never MSYS/Git Bash.

---

## 5. What's next (priority order)

0. **Autosurvey repair: Tasks 1-8, strict order, one concern per spec** (the 24 h survey died; analysis done). **STATUS 2026-10-23: Tasks 1-8 AND Part 7 (frozen final window, infinite final retry, non-fatal 540-min watchdog in PPP-AR mode, heartbeat) are DONE in `main`; deployed to Topolchane up to `e48e389`; a 6 h smoke survey is running. Remaining: deploy the later fixes after the smoke survey, then the 24 h survey; Settings UI does not show the new final-retry indicators yet.** The list below is the original task description:
   1. **daemon-reload as a CRITICAL OTA/post_update step** (`perform_update.sh`, `tools/post_update.sh`, startup self-heal when `NeedDaemonReload=yes`). Restart only changed units that were active per snapshot; never start inactive units; never touch `rtkbase_web` from post_update; verify no `NeedDaemonReload=yes` remains; audit.log; watchdog warning. Root causes to find: why `copy_unit.sh` line 72 `daemon-reload` had no effect on the Oct-10 OTA; why the journald drop-in was reported missing on Oct 13. (01a helpers `tools/unit_reload.sh`, `addons/unit_reload_check.py`, `tests/unit_reload_test.sh` exist uncommitted; decide if both shell and Python are needed.)
   2. **File-service ownership per the SURVEY-ONLY policy (§3)**, then **watchdog/UI alignment** with that policy.
   3. **Survey data selection:** only data from the current survey's start to slot end, never old zips; merge all segments in time order into ONE continuous obs; PRIDE `Session time` must match.
   4. **30 s decimation** + `Interval = 30` (PPP currently uses 1 Hz).
   5. **Frequency selection actually applied** (F9P `G12 R12 E17`; UM980 `G12 R12 E15 C26`); `frequency_selection` is null in attempt records today.
   6. **Survey as its own systemd service** (e.g. `geomaxima_survey.service`), reconcile/resume on start ("resumed after interruption"), pdp3/convbin in their own process group with an enforced timeout (kill group, no orphans), OTA must not kill a running survey.
   7. **Retry policy by error class** (timeout / no data / conversion / parse / product); no identical reruns of deterministic failures; meaningful reasons. Infinite retry for the final result stays.
   8. **`antenna_info` literal quotes** (`'ADVNULLANTENNA'`) fix + migration.
   - Do NOT start a new survey and do NOT OTA Topolchane until 1-6 are done. The stale `running` in `survey_state.json` is fixed by reconcile (task 6), never by hand.
   - Ownership/restore of the File service when the runner dies belongs to tasks 2 and 6.
1. **Pending from the last session (verify):**
   - Remote branch `feature/armbian-opi4pro-support` deleted? (`git ls-remote origin` heads)
   - raspi-config/SPI and other RPi-only OTA steps gated on `GM_PLATFORM` (skip with INFO on Armbian)? Was the commit made?
   - `docs/autosurvey_status.md` updated?
2. **BS-Topolchane after the power outage:** read-only post-boot checks (`journalctl --list-boots`, `dmesg` ext4/mmc errors, `systemctl --failed`, File service enabled+active, new .ubx growing, position unchanged). Then **OTA to the latest main** and verify `post_update` + `before_update`/`after_update` events in audit.log (the first real post_update run on RPi).
3. **First nightly archive run under the new script:** check audit.log / journal for `archive_and_clean` events; no unexpected deletions.
4. **Antenna settings bug:** `antenna_info` is stored with literal quotes (`'ADVNULLANTENNA'`) and isn't found in `merged.atx`. Fix the quoting. Then set Topolchane to K700, uncalibrated, ARP height 0.
5. **First real 24 h Autosurvey WITH PPP-AR enabled** on Topolchane (`ppp_ar_enabled` is false today). Verify in the logs: frequency combination (`G12 R12 E17`), PPP-AR ATTEMPT lines, WL/NL fix rates vs the 90 % gate, heartbeat/UI indicators, File-logging ownership hand-back.
6. **Part 7:** frozen final window, `finalizing` state, retry until accepted, remove the 540-min watchdog, 24 h heartbeat.
7. **Part 11a:** SOFI validation harness. Compare against the official ETRF2000@2005.0 and add acceptance tests for 5 mm / 10 mm.
8. **Part 10b follow-up:** station-specific ETRF2000 velocity (EPND or a Bulgarian velocity model, vendored with provenance) replacing the SOFI proxy.
9. **Part 11b:** differential PPP design report.
10. **Open 6b items:** pdp3 behaviour with missing frequencies, header lines, exact `antenna_info` 20-char IGS string handling.
11. **UM980 support end-to-end** (RTCM3 MSM7 logging, `G12 R12 E15 C26`, AS-ANT3B-CAL calibration; the NGS entry covers G01/G02 only).
12. Recommendation for production: a UPS/battery HAT on every station (SD-card safety, continuous data for чл.57).

---

## 6. Task spec template (Claude → qwen3.8)

Every delegation uses this structure. Small tasks: one concern per spec.

```
TASK: <one-line goal>
CONTEXT: <why; root cause or evidence; relevant rules from CLAUDE.md §3>
FILES TO CHANGE: <exact paths>          FILES NOT TO TOUCH: <paths / "everything else">
REQUIRED BEHAVIOUR:
  1. ...
  2. ...
CONSTRAINTS: <invariants that must hold: position never changes on OTA, no hardcoded DNS, git as repo owner, never logname, bash pitfalls from §8 ...>
TESTS TO ADD: <cases; must exercise REAL code paths / REAL repo tree, not mocks of the thing under test>
ACCEPTANCE: <exact commands that must pass on Linux, expected output>
OUT OF SCOPE: <what must not be changed or "improved">
REPORT BACK: list of changed files, what each change does, test output. Do NOT commit.
```

---

## 6a. How Claude delegates: aider + local qwen3.8

Claude never edits code files. It writes the task spec to a file and runs **aider** non-interactively against the local qwen3.8 model, passing only the files in the spec:

```bash
# spec written by Claude to .aider-tasks/<task-id>.md (gitignored)
aider \
  --model "$GM_CODER_MODEL" \
  --message-file .aider-tasks/<task-id>.md \
  --file path/to/file_to_change.py --file tests/new_test.sh \
  --read CLAUDE.md --read path/to/reference_only.py \
  --no-auto-commits --no-dirty-commits \
  --no-suggest-shell-commands \
  --yes-always
```

Rules for every aider run:
- **`--no-auto-commits` and `--no-dirty-commits` are mandatory.** aider commits by default; only Claude commits, after review and Pesho's approval.
- **`--no-suggest-shell-commands`**: the coder never runs commands. Claude runs the tests.
- Files to change go in `--file`. Context the coder must not edit goes in `--read` (always include `CLAUDE.md`).
- One task per run. After the run, Claude does `git diff` + `git status` and applies the §7 checklist. Any file changed outside the spec is reverted (`git checkout -- <file>`) and the run is repeated with a tighter spec.
- Corrections go through a new spec file (`.aider-tasks/<task-id>-fix-N.md`) naming file, line, problem and expected result.
- If aider/the model fails or produces nonsense twice in a row on the same task, Claude stops and reports to Pesho instead of coding it itself.

Practical rules learned from the first runs (aider 0.86.2):
- **`--yes-always` auto-adds every file named in the spec text** to the chat → context explodes (85k) and no edits happen. In specs, refer to other files only if they are in `--read`; otherwise describe them without a path, or keep paths out of prose.
- For small files use `--edit-format whole` and `--map-tokens 0` (SEARCH/REPLACE blocks failed to match on bigger files).
- State/data file formats must be given **exactly** in the spec (e.g. plain-text "unit active enabled" lines); qwen guessed JSON once.
- Smaller specs win: one function or one script per run.
- Fallback model for an A/B: `mistralai/devstral-small-2-2512` (only after qwen failed twice on the same task, and only with Pesho's OK).

Configuration (set once by Pesho; Claude checks it before the first run of a session):
- Coder: **qwen3.8-27b served by LM Studio at `http://localhost:1234`**, default in `.aider.conf.yml`. `GM_CODER_MODEL` (env) or `.aider.conf.yml` holds the aider model id. Claude must not guess it. If it isn't set, ask.
- If the model is served by Ollama instead, `OLLAMA_API_BASE` must point to it (default `http://127.0.0.1:11434`).
- `.gitignore` must contain `.aider*` and `.aider-tasks/`.
- Sanity check before the first task: `aider --version` and a trivial dry task on a scratch file, then `git status` must be clean.

---

## 7. Review checklist (Claude, mandatory for every diff)

- [ ] The diff touches **only** the files in the spec; no unrelated refactors or reformatting.
- [ ] It does what the spec says, and the root cause is fixed, not the symptom.
- [ ] §3 rules hold: position, ellipsoidal height/ECEF invariant, ETRF2000, DNS rules, service-state preservation, no station-side manual steps.
- [ ] Bash: `set -u`-safe, quoting, numeric validation without octal traps (`10#`, `^[1-9][0-9]*$`), no temp files under `ProtectSystem=strict` (`/tmp` is read-only there), every `$?` and failure handled, no silent `2>/dev/null` on things that matter.
- [ ] Runs correctly in a **non-interactive systemd context**: no `logname`, no reliance on `$HOME`/cwd/TTY, git as the repo owner (`sudo -u`), not root.
- [ ] Every parent version that will execute it is considered (the OTA script self-copies **before** reset, so the OLD script runs the NEW tree). Cross-version paths match (`git show <deployed hash>:...`).
- [ ] Web restart is still the last OTA step; restore runs before it.
- [ ] Audit logging for destructive/UI actions; JSON escaped; the audit log is writable by the user that writes it.
- [ ] Tests exercise the real thing (real lookup paths, real repo tree, real sandbox where it matters). A test that mocks the bug away doesn't count.
- [ ] Full suite run on **Linux (WSL Ubuntu 24.04)**. Pass/fail counts per file reported. Only the known `loop_emmc_test.sh` failures are allowed.
- [ ] Executable bits preserved for `.sh` files (`git ls-files -s`).
- [ ] Commit message states root cause, confirmed vs unproven, and what was verified. No invented causes.

---

## 8. Hard-won lessons (do not repeat)

- **Octal:** `(( 08 < 14 ))` errors in bash, so the condition is false and validation is bypassed. Normalise with `10#` or forbid leading zeros.
- **`ProtectSystem=strict`:** `/tmp` is read-only. A failed redirection means bash never runs the command at all.
- **`logname`** fails in systemd units. Never use it.
- **cgroups:** `Popen`/`start_new_session` stays in `rtkbase_web`'s cgroup. Restarting the web kills children. Use `systemd-run --no-block --working-directory=...` (a transient unit doesn't inherit cwd/env).
- **`systemd-run` + `Type=oneshot` blocks** until the script ends. Use `--no-block`.
- **OTA self-copy:** the running OTA script is always the OLD version. New post-reset logic must live in `tools/post_update.sh` (read fresh) **and/or** the web startup self-heal.
- **Path mismatches kill hand-offs silently** (`addons/tools/post_update.sh` vs `tools/post_update.sh` meant post_update never ran). Test the real lookup.
- **Upstream `ServiceController.stop()` disables the unit.**
- **Branch by name vs upstream:** OTA must use `@{u}`; a local branch name can differ from what it tracks.
- **grep hides continuation lines** (`networkctl` multi-line DNS). Read full output before concluding.
- **The journal was volatile** before the fix; logs before a reboot were lost. It is now persistent.
- Don't attribute causes without evidence. Separate "confirmed" from "unproven" in reports and commit messages.
- **Check the audit.log before blaming code** for a service that "stopped by itself": the 2026-10-10 File-service stop was the operator in the UI, not an ownership bug.
- **`NeedDaemonReload=yes`** means systemd runs the OLD unit file. After any unit change, verify the reload really took effect.
- **gunicorn worker timeout kills the survey loop** (it runs inside a worker); long jobs must be their own service with reconcile.
- PRIDE: T/W/N comes from `cst_*`; resolvable sats from the `amb_*` header; the AMB FIXING flag from the pos/amb header; `sort -u` sorts text, not times.

---

## 9. Communication

- Pesho writes Bulgarian. **Claude answers Pesho in Bulgarian.** Task specs for qwen3.8 and commit messages are in **English**.
- Station commands go in code blocks, read-only, with a short note on what output is expected.
- Report each commit as: hash + one-line summary + `git ls-remote origin refs/heads/main`.
