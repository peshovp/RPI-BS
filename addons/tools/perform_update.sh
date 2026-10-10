#!/bin/bash
#
# Standalone update script
# This runs independently from Flask process
#

# GeoMaxima: run from a private copy. bash reads a script incrementally
# while executing it, and `git reset` below replaces this very file. git
# replaces files by unlink + create, so an already-open copy would keep
# reading the old content - but a rewrite in place (an editor, a future
# git change) would make bash continue at the old byte offset inside the
# NEW file. Copying first makes the running updater immune to whatever
# happens to the file on disk. GM_UPDATER_COPY marks the copy.
if [ -z "${GM_UPDATER_COPY:-}" ]; then
    if GM_UPDATER_COPY="$(mktemp /tmp/perform_update.XXXXXX.sh)" && cp "$0" "$GM_UPDATER_COPY"; then
        export GM_UPDATER_COPY
        exec bash "$GM_UPDATER_COPY" "$@"
    fi
    GM_UPDATER_COPY=""   # copy failed - run in place
fi

set -e

# Log everything to /tmp/ota_update.log for debugging. This already
# captures every command's output, so commands below must NOT also pipe
# through `tee -a /tmp/ota_update.log` - that wrote every such line to the
# log twice (confirmed live: every [dns] line appeared twice).
exec 1> >(tee -a /tmp/ota_update.log)
exec 2>&1

# Any exit other than the explicit success at the end is a FAILED update -
# including `set -e` aborts. The status file must never be left saying
# "running" or "success" in that case. (log_status is defined below; the
# trap only fires once the script is running.)
GM_UPDATE_DONE=0
GM_ERROR_REPORTED=0
gm_on_exit() {
    local rc=$?
    [ -n "${GM_UPDATER_COPY:-}" ] && rm -f "$GM_UPDATER_COPY"
    # Only if nothing more specific was reported (log_status "error" sets
    # GM_ERROR_REPORTED) - never overwrite e.g. the git reset error text.
    if [ "$GM_UPDATE_DONE" != 1 ] && [ "$rc" -ne 0 ] && [ "$GM_ERROR_REPORTED" != 1 ]; then
        log_status "error" "❌ Update FAILED (exit $rc, failing command at line ${GM_LAST_LINE:-?}) - see /tmp/ota_update.log" 2>/dev/null || true
    fi
}
trap 'GM_LAST_LINE=$LINENO' ERR
trap gm_on_exit EXIT

echo "=========================================="
echo "OTA UPDATE STARTED: $(date)"
echo "=========================================="

DEV_REPO_PATH="${1:?Repo path argument required}"
STATUS_FILE="$2"
# GeoMaxima - 2026-10-07 review fix: run_id, matched against the
# pre-shutdown snapshot addons/ota_service_snapshot.py wrote (see
# addons/features/ota_update/update_controller.py's perform_update(),
# which passes this same value as argument 3) - optional, so a manual/
# CLI run with no run_id still works (never trusts a snapshot without a
# matching run_id, just falls back to a snapshot taken from inside this
# script instead).
GEOMAXIMA_RUN_ID="${3:-}"

echo "DEV_REPO_PATH=$DEV_REPO_PATH"
echo "STATUS_FILE=$STATUS_FILE"

if [ ! -d "$DEV_REPO_PATH/.git" ]; then
    echo "❌ ERROR: $DEV_REPO_PATH is not a valid git repository"
    exit 1
fi

# GeoMaxima: git >= 2.35.2 refuses to operate on a repository not owned by
# the current UID ("detected dubious ownership in repository at ...")
# unless explicitly allowlisted via safe.directory - confirmed live to
# break install.sh's phase-2 flow (a separate script) when running as
# root under systemd, where SUDO_UID (which git also honors as an
# implicit owner-match under a normal `sudo` invocation) is never set.
#
# Fixed here by running every git operation below AS THE REPO'S ACTUAL
# OWNER (derived from the directory itself via `stat -c '%U'` - matching
# the existing REPO_OWNER_FOR_ANTEX/PRIDE_PPPAR_USER pattern already used
# further down in this same script, never a hardcoded username), not by
# allowlisting root as a safe.directory user. The repo belongs to the
# install user; root should not become a git user of it. This is also why
# the pre-existing `git config --system --replace-all safe.directory ...`
# line that used to be here was removed - it wrote to /etc/gitconfig
# (persistent, system-wide, EVERY repo on the machine, not scoped to this
# one), which install.sh/tools/geomaxima-firstboot.sh take a narrower,
# per-process approach to avoid (see their own comments) - this script now
# avoids it entirely rather than narrowing it, since running as the owner
# makes the allowlist unnecessary in the first place.
GM_REPO_OWNER="$(stat -c '%U' "$DEV_REPO_PATH")"
if [[ -z "$GM_REPO_OWNER" || "$GM_REPO_OWNER" == "root" ]]; then
    echo "⚠ Could not determine a non-root owner for $DEV_REPO_PATH (stat reported '${GM_REPO_OWNER:-<empty>}') - git operations will run as the current user instead. If this repo is genuinely owned by a non-root user, this is unexpected." >&2
    GM_GIT_AS_OWNER() { "$@"; }
else
    GM_GIT_AS_OWNER() { sudo -u "$GM_REPO_OWNER" "$@"; }
fi

# Logging function
log_status() {
    local status="$1"
    local message="$2"

    # STATUS_FILE is optional - empty when this script is run manually
    # without a second argument (confirmed live: an empty string makes
    # Python's Path('') resolve to '.', the current directory, which
    # exists() as True but then fails open(status_file, 'r') with
    # "IsADirectoryError: [Errno 21] Is a directory: '.'" on every single
    # log_status call - skip the JSON status write entirely rather than
    # hitting that every time.
    [ "$status" = "error" ] && GM_ERROR_REPORTED=1
    [ -z "$STATUS_FILE" ] && return 0

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%6N")

    # GeoMaxima: values are passed as arguments, never pasted into the
    # Python source. The former '${message}' interpolation broke on any
    # message containing a quote (confirmed live: SyntaxError on "never the
    # 'wireguard' metapackage"), silently dropping that status line.
    python3 - "$STATUS_FILE" "$status" "$message" "$timestamp" <<'PYEOF' || true
import json, sys
from pathlib import Path
path, status, message, timestamp = sys.argv[1:5]
status_file = Path(path)
try:
    if status_file.exists():
        with open(status_file) as f:
            data = json.load(f)
    else:
        data = {'success': False, 'log': '', 'completed': False, 'timestamp': timestamp}
    data['log'] = data.get('log', '') + message + '\n'
    if status == 'success':
        data['success'] = True
        data['completed'] = True
    elif status == 'error':
        data['success'] = False
        data['completed'] = True
        data['error'] = message
    status_file.parent.mkdir(parents=True, exist_ok=True)
    with open(status_file, 'w') as f:
        json.dump(data, f, indent=2)
except Exception as e:
    print(f'Error updating status: {e}', file=sys.stderr)
PYEOF
}

log_status "info" "📦 Repo: $DEV_REPO_PATH"

cd "$DEV_REPO_PATH" || exit 1

# ============================================================================
# OWNERSHIP - before ANY git command
# ============================================================================
# git runs as the repo owner (GM_GIT_AS_OWNER). Anything in the working
# tree or .git that isn't the owner's - left by older root-run git, or
# written by root services - makes git fail on it. Confirmed live: a
# root-owned tests/ directory made `git reset --hard` fail half-way, and
# root-owned .git/objects directories can make a fetch fail. Hand it all
# back to the owner first (see tools/repo_update.sh).
log_status "info" "Checking repository ownership..."
if sudo bash -c "source '${DEV_REPO_PATH}/tools/repo_update.sh' && geomaxima_repo_normalize_ownership '${DEV_REPO_PATH}'" 2>&1; then
    log_status "info" "✓ Repository ownership OK"
else
    log_status "error" "Could not give the repository back to its owner ($GM_REPO_OWNER) - git would fail on root-owned files. See /tmp/ota_update.log."
    exit 1
fi

# ============================================================================
# ROBUST GIT STATE RECOVERY
# ============================================================================
log_status "info" "Cleaning up git state..."

# Remove any stale git lock files that can cause HTTP 409 CONFLICT
rm -f .git/index.lock 2>/dev/null || true
log_status "info" "✓ Removed stale git lock"

# Recover from incomplete merge
if [ -d ".git/MERGE_HEAD" ]; then
    log_status "info" "Recovering from incomplete merge..."
    GM_GIT_AS_OWNER git merge --abort 2>&1 || true
fi

# Recover from incomplete rebase
if [ -d ".git/rebase-merge" ]; then
    log_status "info" "Recovering from incomplete rebase..."
    GM_GIT_AS_OWNER git rebase --abort 2>&1 || true
fi

# Discard any uncommitted changes to avoid merge conflicts
log_status "info" "Discarding uncommitted changes..."
GM_GIT_AS_OWNER git checkout -- . 2>&1 || true

log_status "info" "✓ Git state cleaned and ready"

log_status "info" "Stashing local changes..."
GM_GIT_AS_OWNER git stash push -m "Auto-stash before update $(date)" 2>&1 || log_status "info" "No changes to stash"

log_status "info" "✓ Local changes stashed"
log_status "info" "Fetching latest updates..."

# Retry with backoff for flaky networks. GeoMaxima: the former loop was
# `until git fetch ... | tee ...`, which tests TEE's exit status (always
# 0) - a failed fetch was never retried and never detected, and the
# `git reset --hard origin/<branch>` below then "applied" the stale
# remote-tracking ref and reported success. Now git's own exit status is
# checked. Six attempts over ~4 min ride out bursty DNS/network failures.
# A DNS failure is named as such so it isn't mistaken for a GitHub or
# authentication problem.
RETRY_COUNT=0
MAX_RETRIES=6
while :; do
    # (`&& ... || ...` form: this script runs under `set -e`, which would
    # otherwise abort on the failing assignment itself.)
    FETCH_OUT="$(GM_GIT_AS_OWNER git fetch origin 2>&1)" && FETCH_RC=0 || FETCH_RC=$?
    printf '%s\n' "$FETCH_OUT"
    [ $FETCH_RC -eq 0 ] && break
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if printf '%s' "$FETCH_OUT" | grep -qiE 'Could not resolve host|Temporary failure in name resolution|Name or service not known|Resolving timed out'; then
        FETCH_WHY="DNS resolution failed (the station could not resolve the git host - check the DNS its network provides; see Watchdog > DNS)"
    else
        FETCH_WHY="git fetch exited $FETCH_RC"
    fi
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        log_status "error" "Git fetch failed after $MAX_RETRIES attempts: $FETCH_WHY"
        exit 1
    fi
    log_status "info" "⚠ Fetch failed ($FETCH_WHY), retrying ($RETRY_COUNT/$MAX_RETRIES) in $((RETRY_COUNT * 15))s..."
    sleep $((RETRY_COUNT * 15))
done

log_status "info" "✓ Fetched from origin"
log_status "info" "Getting current branch..."

# (`&& ... || ...` form throughout: under `set -e` a failing assignment
# would otherwise abort before the error could be reported.)
BRANCH="$(GM_GIT_AS_OWNER git rev-parse --abbrev-ref HEAD 2>&1)" && BRANCH_RC=0 || BRANCH_RC=$?
if [ $BRANCH_RC -ne 0 ]; then
    log_status "error" "Failed to get current branch: $BRANCH"
    exit 1
fi
log_status "info" "✓ Current branch: $BRANCH"
log_status "info" "Resetting to remote HEAD to avoid conflicts..."

# Use hard reset instead of pull to avoid merge conflicts entirely.
# GeoMaxima: the reset was piped through `tee`, so its failure was never
# seen - confirmed live: "unable to unlink old ... Permission denied" /
# "Could not reset index file", and the update carried on and reported
# success with HEAD still on the old commit. Now git's own status is
# checked, and the result is verified: HEAD must equal origin/<branch>
# with no tracked changes left. Anything else stops the update as FAILED.
RESET_OUT="$(GM_GIT_AS_OWNER git reset --hard "origin/$BRANCH" 2>&1)" && RESET_RC=0 || RESET_RC=$?
printf '%s\n' "$RESET_OUT"
if [ $RESET_RC -ne 0 ]; then
    log_status "error" "Git reset to origin/$BRANCH FAILED (exit $RESET_RC): $(printf '%s' "$RESET_OUT" | grep -iE 'error|fatal' | head -3 | tr '\n' ' ')"
    exit 1
fi
GM_HEAD="$(GM_GIT_AS_OWNER git rev-parse HEAD 2>/dev/null)" || GM_HEAD=""
GM_TARGET="$(GM_GIT_AS_OWNER git rev-parse "origin/$BRANCH" 2>/dev/null)" || GM_TARGET=""
GM_DIRTY="$(GM_GIT_AS_OWNER git status --porcelain --untracked-files=no 2>&1)" || GM_DIRTY="git status failed: $GM_DIRTY"
if [ -z "$GM_HEAD" ] || [ "$GM_HEAD" != "$GM_TARGET" ] || [ -n "$GM_DIRTY" ]; then
    log_status "error" "Git reset did not complete: HEAD ${GM_HEAD:0:7}, origin/$BRANCH ${GM_TARGET:0:7}, tracked changes: $(printf '%s' "$GM_DIRTY" | head -5 | tr '\n' ' ')"
    exit 1
fi
log_status "info" "✓ Updates applied successfully: $(GM_GIT_AS_OWNER git log -1 --oneline 2>/dev/null)"
log_status "info" "Ensuring SPI is enabled (idempotent, needed for optional LCD display feature)..."
sudo raspi-config nonint do_spi 0 2>&1 || log_status "info" "⚠ raspi-config SPI enable failed - continuing anyway"

log_status "info" "Ensuring fonts-dejavu-core is installed (idempotent, needed for optional LCD display feature)..."
sudo apt-get install -y -qq --no-remove fonts-dejavu-core 2>&1 || log_status "info" "⚠ fonts-dejavu-core install failed - continuing anyway"

log_status "info" "Ensuring WireGuard tooling is installed (idempotent - never the 'wireguard' metapackage, see tools/wireguard_setup.sh)..."
# GeoMaxima: same shared helper install.sh uses - re-applied on every OTA
# run so a station that never had WireGuard, or whose kernel changed
# (e.g. a future Armbian vendor-kernel update that DOES add native
# WireGuard support), converges on the right package set. NEVER installs
# the Debian `wireguard` metapackage - see tools/wireguard_setup.sh's
# header comment for the confirmed-live root cause (that metapackage
# depends on wireguard-modules, only provided by Debian's own
# linux-image-* kernel packages, which would pull in a Debian-origin
# kernel alongside this board's vendor kernel).
#
# Sourced by ABSOLUTE path (built from $DEV_REPO_PATH, the repo path this
# script already receives as $1) rather than the relative "tools/..." the
# rest of this script's own cwd-relative calls use - `sudo bash -c '...'`
# launches a NEW shell whose cwd, while normally inherited from the caller,
# should not be relied on across a sudo boundary here.
#
# Commands are not piped through `tee` (stdout is already logged, see the
# top), so `if ! cmd` sees the helper's own exit status - and a failure
# can't trip `set -e`.
if ! sudo bash -c "source '${DEV_REPO_PATH}/tools/wireguard_setup.sh' && geomaxima_install_wireguard" 2>&1; then
    log_status "info" "⚠ WireGuard setup failed - continuing anyway (optional feature, does not affect RTCM/GNSS)"
fi

log_status "info" "DNS: openresolv step (now a no-op - see tools/dns_setup.sh)..."
# GeoMaxima: kept as a call so this script and older copies of it behave
# the same; the function no longer installs anything.
sudo bash -c "source '${DEV_REPO_PATH}/tools/dns_setup.sh' && geomaxima_maybe_install_openresolv" 2>&1 || true

log_status "info" "DNS: removing injected public resolvers and WireGuard DNS lines (idempotent, verified, auto-rollback)..."
# GeoMaxima: DNS policy - only the DNS the station's own network provides;
# no public resolver, never from WireGuard. geomaxima_configure_dns_fallback()
# (name kept: older copies of THIS script, still running on stations during
# the OTA that delivers the fix, call it by this name after `git reset` has
# already put the new tools/dns_setup.sh on disk) now migrates stations off
# the 8.8.8.8/1.1.1.1 injection and the WireGuard exclusive-DNS entry,
# without restarting WireGuard or bouncing the link, and rolls everything
# back if resolution gets worse. See tools/dns_setup.sh's header comment.
# Verification on a live station after this runs:
#   cat /etc/resolv.conf     (router/ISP resolvers only)
#   resolvconf -l            (no wg0 entry)
#   cat /var/lib/rtkbase/dns_migration.json
if ! sudo bash -c "source '${DEV_REPO_PATH}/tools/dns_setup.sh' && geomaxima_configure_dns_fallback" 2>&1; then
    log_status "info" "⚠ DNS migration was rolled back or failed - see the [dns] lines above (does not affect RTCM/GNSS)"
fi

log_status "info" "Verifying DNS resolution is still working after the DNS/WireGuard setup steps above..."
# GeoMaxima: never aborts the OTA. The code is already updated at this
# point (git reset above); stopping here would skip the ANTEX/PRIDE steps
# and the service restart, leaving the station half-updated. A DNS failure
# is logged here and shown by the watchdog (Watchdog > DNS) instead.
# GM_DNS_HEALTH_FATAL=1 only so the function reports the real result.
if ! sudo bash -c "GM_DNS_HEALTH_FATAL=1; source '${DEV_REPO_PATH}/tools/dns_setup.sh' && geomaxima_dns_health_check" 2>&1; then
    log_status "info" "⚠ DNS resolution is not working through the network's DNS - continuing the update anyway (see the diagnostics above and Watchdog > DNS); downloads later in this update may fail."
fi

log_status "info" "Ensuring ANTEX (igs20.atx) is present (idempotent, needed for optional PPP-static feature)..."
ANTEX_DIR="$DEV_REPO_PATH/geomaxima_ppp"
ANTEX_PATH="$ANTEX_DIR/igs20.atx"
if [ -f "$ANTEX_PATH" ]; then
    log_status "info" "✓ ANTEX file already present, skipping download"
else
    # GeoMaxima: written as the repo owner (GM_GIT_AS_OWNER is a plain
    # "run as the owner" wrapper), never as root inside the working tree.
    # geomaxima_ppp/ is gitignored.
    GM_GIT_AS_OWNER mkdir -p "$ANTEX_DIR" 2>&1 || true
    if GM_GIT_AS_OWNER curl -fsSL "https://files.igs.org/pub/station/general/igs20.atx.gz" -o "$ANTEX_DIR/igs20.atx.gz" 2>&1; then
        if GM_GIT_AS_OWNER gzip -d "$ANTEX_DIR/igs20.atx.gz" 2>&1; then
            log_status "info" "✓ ANTEX file downloaded and decompressed"
        else
            log_status "info" "⚠ ANTEX decompression failed - PPP-static will not work until resolved manually"
        fi
    else
        log_status "info" "⚠ ANTEX download failed (network issue?) - PPP-static will not work until resolved - will retry on next update"
    fi
fi

log_status "info" "Ensuring PRIDE-PPPAR (pdp3) is installed (idempotent, needed by optional PPP-AR feature)..."
# Same install-user/home resolution already used for REPO_OWNER below
# (stat -c '%U' "$DEV_REPO_PATH") - resolved here too since this check runs
# before that variable is otherwise needed. Never hardcoded to any specific
# username. Mirrors install.sh's own PRIDE-PPPAR step exactly (idempotency
# check, -O0 gfortran-aarch64-ICE workaround, non-interactive build,
# warning-only failure) so pre-existing stations (e.g. BaseStation) that
# ran an older install.sh without this step get pdp3 installed automatically
# on their next OTA update, with no manual per-station step required.
PRIDE_PPPAR_USER=$(stat -c '%U' "$DEV_REPO_PATH")
PRIDE_PPPAR_USER_HOME="$(getent passwd "$PRIDE_PPPAR_USER" | cut -d: -f6)"
PRIDE_PPPAR_USER_HOME="${PRIDE_PPPAR_USER_HOME:-/root}"
PRIDE_PPPAR_BIN="${PRIDE_PPPAR_USER_HOME}/.PRIDE_PPPAR_BIN/pdp3"

# Vendored source (addons/PRIDE-PPPAR/, committed to this repo) - no longer
# cloned from GitHub at update time. Mirrors install.sh's own PRIDE-PPPAR
# step exactly: PrideLab/PRIDE-PPPAR's own install.sh writes build outputs
# into ./src and reads ./table/config_template, so it must run from a
# writable COPY of the vendored tree, not directly against this repo's
# checkout - copied into the install user's home directory. This also
# removes the prior network dependency entirely (no more GitHub clone, no
# more transient "Could not resolve host" failures at remote sites like
# BaseStation - see the removed retry logic this replaces).
PRIDE_PPPAR_VENDORED_SRC="$DEV_REPO_PATH/addons/PRIDE-PPPAR"

# Marker file recording a content hash of the vendored source tree as of
# the last successful build - lets this step tell "pdp3 exists" apart from
# "pdp3 exists AND matches the currently-vendored source". Without this,
# once pdp3 was built once on a station, every later OTA update would skip
# this step forever (the old `[ -x "$PRIDE_PPPAR_BIN" ]`-only check), so a
# future fix to vendored PRIDE-PPPAR source (e.g. a redig.f90 segfault fix)
# would never reach an already-installed station through the normal OTA
# path.
#
# CONFIRMED LIVE BUG (BaseStation, 2026-09-24): an earlier version of this
# hash restricted itself to src/, install.sh, and README.md only - but the
# igs.gnsswhu.cn timeout fix (commit dd9f0bd) lives in scripts/pdp3.sh,
# which that filter did NOT cover, so the hash never changed and the
# rebuild was silently skipped despite the vendored source having
# genuinely changed. Hashing the ENTIRE vendored tree (no path filter)
# instead, so no future file added/changed anywhere under
# addons/PRIDE-PPPAR/ can silently bypass this check again.
PRIDE_PPPAR_HASH_FILE="${PRIDE_PPPAR_USER_HOME}/.PRIDE_PPPAR_BIN/.source_hash"
PRIDE_PPPAR_CURRENT_HASH=""
if [ -d "$PRIDE_PPPAR_VENDORED_SRC" ]; then
    PRIDE_PPPAR_CURRENT_HASH=$(find "$PRIDE_PPPAR_VENDORED_SRC" -type f -exec sha256sum {} \; | sort | sha256sum | awk '{print $1}')
fi

PRIDE_PPPAR_NEEDS_BUILD=1
PRIDE_PPPAR_STORED_HASH=""
if [ -f "$PRIDE_PPPAR_HASH_FILE" ]; then
    PRIDE_PPPAR_STORED_HASH="$(cat "$PRIDE_PPPAR_HASH_FILE" 2>/dev/null)"
fi
if [ -x "$PRIDE_PPPAR_BIN" ] && [ -n "$PRIDE_PPPAR_STORED_HASH" ] && [ "$PRIDE_PPPAR_STORED_HASH" = "$PRIDE_PPPAR_CURRENT_HASH" ]; then
    PRIDE_PPPAR_NEEDS_BUILD=0
fi

if [ "$PRIDE_PPPAR_NEEDS_BUILD" -eq 0 ]; then
    log_status "info" "✓ PRIDE-PPPAR already installed at $PRIDE_PPPAR_BIN and matches vendored source - skipping build"
elif [ ! -d "$PRIDE_PPPAR_VENDORED_SRC/src" ]; then
    log_status "info" "⚠ vendored PRIDE-PPPAR source not found at $PRIDE_PPPAR_VENDORED_SRC - skipping (opt-in feature, rnx2rtkp unaffected)"
else
    if [ -x "$PRIDE_PPPAR_BIN" ]; then
        # Binary exists but the vendored source hash has changed since the
        # last build (or no marker was ever recorded) - this is the case
        # the live BaseStation bug hit: a real fix landed in
        # addons/PRIDE-PPPAR/ but was never rebuilt because the old hash
        # filter didn't cover the changed file.
        log_status "info" "PRIDE-PPPAR vendored source has changed since last build (or no build record found) - rebuilding..."
    fi
    # ATOMIC REBUILD: build into a TEMPORARY location and only swap it onto
    # the real ~/.PRIDE_PPPAR_BIN on a CONFIRMED successful build, instead
    # of building in place. Upstream PRIDE-PPPAR's own install.sh does
    # `rm -rf "$install_dir"` (= ~/.PRIDE_PPPAR_BIN) BEFORE building the
    # new one, with no atomic swap of its own - if the build is
    # interrupted mid-compile, the station is left with NEITHER the old
    # working binary NOR a new one, a strictly worse state than before the
    # update. CONFIRMED LIVE on BaseStation 2026-09-24: a UI-triggered OTA
    # update's PRIDE-PPPAR rebuild was cut off mid-compile
    # ("make[1]: Entering directory '.../src/arsig'", never completing),
    # and ~/.PRIDE_PPPAR_BIN/ was left completely missing afterward - the
    # same script run directly over SSH always completed cleanly. The
    # interruption itself was very likely rtkbase_web.service's systemd
    # KillMode=control-group killing this detached build's cgroup on a
    # service restart (see unit/rtkbase_web.service's own comment on the
    # KillMode=process fix alongside this one) - but this atomic-swap
    # logic is a second, independent line of defense: it must hold
    # regardless of WHY a build gets interrupted (kill -9, OOM, power
    # loss, or anything else), since the old working installation must
    # never be destroyed before a replacement is confirmed ready.
    #
    # Mechanism: build under a throwaway $HOME (upstream install.sh writes
    # to "${HOME}/.PRIDE_PPPAR_BIN" - confirmed by reading that script -
    # so overriding HOME for just this subprocess redirects its output
    # without needing to patch that vendored script), then only copy the
    # confirmed-executable pdp3 binary (and the rest of that temporary
    # .PRIDE_PPPAR_BIN's contents) onto the real target via rename (mv is
    # atomic within the same filesystem, which the same user's $HOME
    # always is here).
    PRIDE_PPPAR_REPO_DIR="${PRIDE_PPPAR_USER_HOME}/PRIDE-PPPAR"
    PRIDE_PPPAR_TMP_HOME="${PRIDE_PPPAR_USER_HOME}/.pride_pppar_build_tmp"
    PRIDE_PPPAR_TMP_BIN="${PRIDE_PPPAR_TMP_HOME}/.PRIDE_PPPAR_BIN"
    PRIDE_PPPAR_REAL_BIN_DIR="${PRIDE_PPPAR_USER_HOME}/.PRIDE_PPPAR_BIN"

    log_status "info" "Copying vendored PRIDE-PPPAR source into $PRIDE_PPPAR_REPO_DIR..."
    rm -rf "$PRIDE_PPPAR_REPO_DIR" "$PRIDE_PPPAR_TMP_HOME"
    mkdir -p "$PRIDE_PPPAR_TMP_HOME"
    chown "$PRIDE_PPPAR_USER":"$PRIDE_PPPAR_USER" "$PRIDE_PPPAR_TMP_HOME" 2>/dev/null || true
    if sudo -u "$PRIDE_PPPAR_USER" cp -r "$PRIDE_PPPAR_VENDORED_SRC" "$PRIDE_PPPAR_REPO_DIR" 2>&1; then

        log_status "info" "Applying -O0 workaround for gfortran aarch64 ICE..."
        find "$PRIDE_PPPAR_REPO_DIR" -name Makefile -exec sed -i 's/-O3/-O0/g; s/-O2/-O0/g; s/-O1/-O0/g' {} \;

        sudo -u "$PRIDE_PPPAR_USER" chmod +x "$PRIDE_PPPAR_REPO_DIR/install.sh" 2>/dev/null || true

        log_status "info" "Building PRIDE-PPPAR (non-interactive, into temporary location)..."
        if (cd "$PRIDE_PPPAR_REPO_DIR" && sudo -u "$PRIDE_PPPAR_USER" env HOME="$PRIDE_PPPAR_TMP_HOME" bash -c 'yes "" | ./install.sh') 2>&1; then
            if [ -x "$PRIDE_PPPAR_TMP_BIN/pdp3" ]; then
                # Build confirmed successful (binary present and
                # executable in the TEMPORARY location) - now, and only
                # now, atomically replace the real installation. mv onto
                # an existing directory fails/merges unpredictably, so
                # swap the old one aside first, move the new one into
                # place, then discard the old one - each mv itself is
                # atomic; only a crash in the ~0-second window between
                # the two mv calls could leave neither in place, an
                # astronomically smaller risk window than a 1-2 minute
                # compile.
                log_status "info" "✓ PRIDE-PPPAR built successfully in temporary location - swapping into place..."
                PRIDE_PPPAR_OLD_BIN_BAK="${PRIDE_PPPAR_REAL_BIN_DIR}.old.$$"
                if [ -d "$PRIDE_PPPAR_REAL_BIN_DIR" ]; then
                    mv "$PRIDE_PPPAR_REAL_BIN_DIR" "$PRIDE_PPPAR_OLD_BIN_BAK"
                fi
                if mv "$PRIDE_PPPAR_TMP_BIN" "$PRIDE_PPPAR_REAL_BIN_DIR"; then
                    rm -rf "$PRIDE_PPPAR_OLD_BIN_BAK"
                    log_status "info" "✓ PRIDE-PPPAR built successfully: $PRIDE_PPPAR_BIN"
                    # No git tag is pinned upstream (vendored source is simply
                    # whatever snapshot was committed to addons/PRIDE-PPPAR/).
                    # Detect and log the actually-installed version from the
                    # vendored tree's own README.md self-report.
                    detected_version=$(grep -oE 'PRIDE-PPPAR ver\.? [0-9]+\.[0-9]+(\.[0-9]+)?' "$PRIDE_PPPAR_REPO_DIR/README.md" 2>/dev/null | head -1)
                    if [ -n "$detected_version" ]; then
                        log_status "info" "PRIDE-PPPAR version installed: $detected_version"
                    else
                        log_status "info" "⚠ PRIDE-PPPAR built successfully but version string could not be detected from README.md"
                    fi
                    # Record what was just built so the next OTA update's
                    # idempotency check can tell this build apart from a stale
                    # one - only skip next time if the vendored source hasn't
                    # changed since this exact hash. Written only after the
                    # atomic swap succeeded, matching the "only update the
                    # marker on confirmed success" rule this step now follows
                    # throughout.
                    echo "$PRIDE_PPPAR_CURRENT_HASH" > "$PRIDE_PPPAR_HASH_FILE" 2>/dev/null \
                        || log_status "info" "⚠ failed to write $PRIDE_PPPAR_HASH_FILE - next update will rebuild unconditionally"
                else
                    # mv into place failed - restore the old installation
                    # (if any) rather than leaving the station with nothing.
                    log_status "info" "⚠ failed to swap new PRIDE-PPPAR build into place - restoring previous installation (opt-in feature, rnx2rtkp unaffected)"
                    [ -d "$PRIDE_PPPAR_OLD_BIN_BAK" ] && mv "$PRIDE_PPPAR_OLD_BIN_BAK" "$PRIDE_PPPAR_REAL_BIN_DIR"
                fi
            else
                log_status "info" "⚠ PRIDE-PPPAR install.sh completed but no pdp3 binary was found in the temporary build location - previous installation (if any) left untouched (rnx2rtkp unaffected)"
            fi
        else
            log_status "info" "⚠ PRIDE-PPPAR build failed - previous installation (if any) left untouched (opt-in feature, rnx2rtkp unaffected) - will retry on next update"
        fi
    else
        log_status "info" "⚠ failed to copy vendored PRIDE-PPPAR source to $PRIDE_PPPAR_REPO_DIR - continuing update (opt-in feature, rnx2rtkp unaffected) - will retry on next update"
    fi
    rm -rf "$PRIDE_PPPAR_TMP_HOME"
fi

log_status "info" "Ensuring /var/log/rtkbase/ exists (idempotent, needed by geomaxima_watchdog.service)..."
# Owned by root, NOT the repo owner - unlike ANTEX above,
# geomaxima_watchdog.service runs as User=root
# (addons/unit/geomaxima_watchdog.service), not as the installing user.
# Without this directory, run_watchdog_check.py's
# logging.FileHandler('/var/log/rtkbase/watchdog.log') call raises
# FileNotFoundError on every run - confirmed live on BaseStation:
# geomaxima_watchdog.service crash-looped every minute via
# geomaxima_watchdog.timer until this was fixed. This step ensures
# already-deployed stations (BaseStation, BaseStation) get this fixed
# automatically on their next OTA update.
sudo mkdir -p /var/log/rtkbase 2>&1 || log_status "info" "⚠ could not create /var/log/rtkbase - continuing anyway"
sudo chown root:root /var/log/rtkbase 2>&1 || log_status "info" "⚠ chown of /var/log/rtkbase to root failed - continuing anyway"

log_status "info" "Redeploying systemd units (unit/ and addons/unit/)..."

REPO_OWNER=$(stat -c '%U' "$DEV_REPO_PATH")
VENV_PYTHON="$DEV_REPO_PATH/rtkbase/venv/bin/python"
if [ ! -x "$VENV_PYTHON" ]; then
    VENV_PYTHON="$DEV_REPO_PATH/venv/bin/python"
fi

if [ -x "$VENV_PYTHON" ]; then
    log_status "info" "Refreshing Python dependencies (requirements.txt) in venv..."
    if sudo "$VENV_PYTHON" -m pip install -q -r "$DEV_REPO_PATH/web_app/requirements.txt" 2>&1; then
        log_status "info" "✓ Python dependencies refreshed"
    else
        log_status "info" "⚠ pip install refresh reported an error - continuing anyway (existing packages untouched)"
    fi
else
    log_status "info" "⚠ venv python not found - skipping dependency refresh"
fi

if [ -x "$DEV_REPO_PATH/tools/copy_unit.sh" ] && [ -x "$VENV_PYTHON" ]; then
    if sudo "$DEV_REPO_PATH/tools/copy_unit.sh" --python_path "$VENV_PYTHON" --user "$REPO_OWNER" 2>&1; then
        log_status "info" "✓ Systemd units redeployed"
    else
        log_status "info" "⚠ copy_unit.sh reported an error - continuing anyway (existing units untouched)"
    fi

    # Enable (idempotent) any addon timers - e.g. geomaxima_watchdog.timer -
    # so new addon units introduced by an update start running automatically,
    # with no manual systemctl step required on any existing station.
    for timer_file in "$DEV_REPO_PATH"/addons/unit/*.timer; do
        [ -e "$timer_file" ] || continue
        timer_name=$(basename "$timer_file")
        sudo systemctl enable --now "$timer_name" 2>&1 || true
    done
else
    log_status "info" "⚠ copy_unit.sh or venv python not found - skipping unit redeploy"
fi

# GeoMaxima - 2026-10-10/13 review fix: confirmed live (OTA to commit
# fccc038 on a test station) that audit-log-access, journald-retention,
# and the service-state restore were NOT applied at all, even though
# all three were already committed at the time. Root cause: this
# script makes a private self-copy of ITSELF to /tmp BEFORE the git
# reset above (see the top of this file - specifically so the reset
# replacing the on-disk file mid-run can't corrupt the running script),
# and update_controller.py's perform_update() resolves and launches
# THIS script before any git pull/reset runs - so the process actually
# executing is always whichever version of perform_update.sh was on
# disk at the START of the OTA. Inlining the post-update steps here (as
# a previous commit did) can therefore NEVER see its own post-reset
# code, no matter how this script is edited - every post-update step
# must live in a SEPARATE script, read fresh from disk AFTER the reset
# above has already landed the new tree. tools/post_update.sh is that
# script - `cat`'d from the just-reset tree and piped to a fresh `bash
# -s`, not executed by path (which could still resolve to a stale
# cached/mmap'd reference in some edge case) - so it is always the
# version that was just pulled, never the one that launched this OTA.
log_status "info" "Running post-update steps from the freshly-updated tree..."
if [ -r "$DEV_REPO_PATH/tools/post_update.sh" ]; then
    if cat "$DEV_REPO_PATH/tools/post_update.sh" | bash -s -- "$DEV_REPO_PATH" "$REPO_OWNER" "$GEOMAXIMA_RUN_ID" 2>&1; then
        log_status "info" "✓ Post-update steps completed"
    else
        log_status "info" "⚠ post_update.sh reported an error - continuing anyway (update itself already succeeded)"
    fi
else
    log_status "info" "⚠ tools/post_update.sh not found in the updated tree - skipping post-update steps"
fi

GM_UPDATE_DONE=1
log_status "success" "✅ Update completed successfully! Restarting the web service now."

# GeoMaxima - 2026-10-05/06 incident investigation: the restart used to
# be backgrounded (`(sleep 5 && systemctl restart rtkbase_web) &`) so
# this script's own `exit 0` ran before the restart fired - intended to
# let the HTTP response complete first, but it meant the restart command
# became an orphaned child of this script's process once the script
# exited, with no guarantee it would survive whatever happens to this
# process tree's cgroup after that (this script is now launched via
# `systemd-run --unit=... --collect`, which abandons/cleans up its
# transient unit's cgroup once the unit's main process exits - a
# detached grandchild is not protected from that cleanup the way it
# would be inside a durable, unrelated unit). The restart is now the
# LAST command this script runs, synchronously, not backgrounded - any
# process this script's own update steps started (e.g. a rebuilt
# PRIDE-PPPAR binary's build step) has already completed by this point
# (every step above is synchronous, `set -e` would have aborted
# otherwise), so there is nothing left running in this script's cgroup
# that the restart could prematurely kill.
sudo systemctl restart rtkbase_web

exit 0
