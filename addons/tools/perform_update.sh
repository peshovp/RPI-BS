#!/bin/bash
#
# Standalone update script
# This runs independently from Flask process
#

set -e

# Log everything to /tmp/ota_update.log for debugging
exec 1> >(tee -a /tmp/ota_update.log)
exec 2>&1

echo "=========================================="
echo "OTA UPDATE STARTED: $(date)"
echo "=========================================="

DEV_REPO_PATH="${1:?Repo path argument required}"
STATUS_FILE="$2"

echo "DEV_REPO_PATH=$DEV_REPO_PATH"
echo "STATUS_FILE=$STATUS_FILE"

if [ ! -d "$DEV_REPO_PATH/.git" ]; then
    echo "❌ ERROR: $DEV_REPO_PATH is not a valid git repository"
    exit 1
fi

git config --system --replace-all safe.directory "$DEV_REPO_PATH" 2>/dev/null || true

# Logging function
log_status() {
    local status="$1"
    local message="$2"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%6N")
    
    # Append to log
    python3 -c "
import json
import sys
from pathlib import Path

status_file = Path('${STATUS_FILE}')
try:
    if status_file.exists():
        with open(status_file, 'r') as f:
            data = json.load(f)
    else:
        data = {'success': False, 'log': '', 'completed': False, 'timestamp': '${timestamp}'}
    
    data['log'] += '${message}\n'
    
    if '${status}' == 'success':
        data['success'] = True
        data['completed'] = True
    elif '${status}' == 'error':
        data['success'] = False
        data['completed'] = True
        data['error'] = '${message}'
    
    with open(status_file, 'w') as f:
        json.dump(data, f, indent=2)
except Exception as e:
    print(f'Error updating status: {e}', file=sys.stderr)
" || true
}

log_status "info" "📦 Repo: $DEV_REPO_PATH"

cd "$DEV_REPO_PATH" || exit 1

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
    git merge --abort 2>&1 || true
fi

# Recover from incomplete rebase
if [ -d ".git/rebase-merge" ]; then
    log_status "info" "Recovering from incomplete rebase..."
    git rebase --abort 2>&1 || true
fi

# Discard any uncommitted changes to avoid merge conflicts
log_status "info" "Discarding uncommitted changes..."
git checkout -- . 2>&1 || true

log_status "info" "✓ Git state cleaned and ready"

log_status "info" "Stashing local changes..."
git stash push -m "Auto-stash before update $(date)" 2>&1 || log_status "info" "No changes to stash"

log_status "info" "✓ Local changes stashed"
log_status "info" "Fetching latest updates..."

# Explicit timeout + retry for flaky networks
RETRY_COUNT=0
MAX_RETRIES=3
until git fetch origin 2>&1 | tee -a /tmp/ota_update.log; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        log_status "error" "Git fetch failed after $MAX_RETRIES retries"
        exit 1
    fi
    log_status "info" "⚠ Fetch failed, retrying ($RETRY_COUNT/$MAX_RETRIES)..."
    sleep 2
done

log_status "info" "✓ Fetched from origin"
log_status "info" "Getting current branch..."

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>&1)
if [ $? -ne 0 ]; then
    log_status "error" "Failed to get current branch: $BRANCH"
    exit 1
fi
log_status "info" "✓ Current branch: $BRANCH"
log_status "info" "Resetting to remote HEAD to avoid conflicts..."

# Use hard reset instead of pull to avoid merge conflicts entirely
git fetch origin "$BRANCH" 2>&1 | tee -a /tmp/ota_update.log || true
if git reset --hard "origin/$BRANCH" 2>&1 | tee -a /tmp/ota_update.log; then
    log_status "info" "✓ Updates applied successfully"
else
    log_status "error" "Git reset failed - repository may be corrupted"
    exit 1
fi
log_status "info" "Ensuring SPI is enabled (idempotent, needed for optional LCD display feature)..."
sudo raspi-config nonint do_spi 0 2>&1 | tee -a /tmp/ota_update.log || log_status "info" "⚠ raspi-config SPI enable failed - continuing anyway"

log_status "info" "Ensuring fonts-dejavu-core is installed (idempotent, needed for optional LCD display feature)..."
sudo apt-get install -y -qq fonts-dejavu-core 2>&1 | tee -a /tmp/ota_update.log || log_status "info" "⚠ fonts-dejavu-core install failed - continuing anyway"

log_status "info" "Ensuring ANTEX (igs20.atx) is present (idempotent, needed for optional PPP-static feature)..."
ANTEX_DIR="$DEV_REPO_PATH/geomaxima_ppp"
ANTEX_PATH="$ANTEX_DIR/igs20.atx"
if [ -f "$ANTEX_PATH" ]; then
    log_status "info" "✓ ANTEX file already present, skipping download"
else
    mkdir -p "$ANTEX_DIR" 2>&1 | tee -a /tmp/ota_update.log
    if curl -fsSL "https://files.igs.org/pub/station/general/igs20.atx.gz" -o "$ANTEX_DIR/igs20.atx.gz" 2>&1 | tee -a /tmp/ota_update.log; then
        if gzip -d "$ANTEX_DIR/igs20.atx.gz" 2>&1 | tee -a /tmp/ota_update.log; then
            log_status "info" "✓ ANTEX file downloaded and decompressed"
            REPO_OWNER_FOR_ANTEX=$(stat -c '%U' "$DEV_REPO_PATH")
            chown -R "$REPO_OWNER_FOR_ANTEX":"$REPO_OWNER_FOR_ANTEX" "$ANTEX_DIR" 2>&1 | tee -a /tmp/ota_update.log || true
        else
            log_status "info" "⚠ ANTEX decompression failed - PPP-static will not work until resolved manually"
        fi
    else
        log_status "info" "⚠ ANTEX download failed (network issue?) - PPP-static will not work until resolved - will retry on next update"
    fi
fi

log_status "info" "Ensuring /var/log/rtkbase/ exists (idempotent, needed by geomaxima_watchdog.service)..."
# Owned by root, NOT the repo owner - unlike ANTEX above,
# geomaxima_watchdog.service runs as User=root
# (addons/unit/geomaxima_watchdog.service), not as the installing user.
# Without this directory, run_watchdog_check.py's
# logging.FileHandler('/var/log/rtkbase/watchdog.log') call raises
# FileNotFoundError on every run - confirmed live on BS-Aheloy:
# geomaxima_watchdog.service crash-looped every minute via
# geomaxima_watchdog.timer until this was fixed. This step ensures
# already-deployed stations (BS-Aheloy, BS-Topolchane) get this fixed
# automatically on their next OTA update.
sudo mkdir -p /var/log/rtkbase 2>&1 | tee -a /tmp/ota_update.log
sudo chown root:root /var/log/rtkbase 2>&1 | tee -a /tmp/ota_update.log || log_status "info" "⚠ chown of /var/log/rtkbase to root failed - continuing anyway"

log_status "info" "Redeploying systemd units (unit/ and addons/unit/)..."

REPO_OWNER=$(stat -c '%U' "$DEV_REPO_PATH")
VENV_PYTHON="$DEV_REPO_PATH/rtkbase/venv/bin/python"
if [ ! -x "$VENV_PYTHON" ]; then
    VENV_PYTHON="$DEV_REPO_PATH/venv/bin/python"
fi

if [ -x "$VENV_PYTHON" ]; then
    log_status "info" "Refreshing Python dependencies (requirements.txt) in venv..."
    if sudo "$VENV_PYTHON" -m pip install -q -r "$DEV_REPO_PATH/web_app/requirements.txt" 2>&1 | tee -a /tmp/ota_update.log; then
        log_status "info" "✓ Python dependencies refreshed"
    else
        log_status "info" "⚠ pip install refresh reported an error - continuing anyway (existing packages untouched)"
    fi
else
    log_status "info" "⚠ venv python not found - skipping dependency refresh"
fi

if [ -x "$DEV_REPO_PATH/tools/copy_unit.sh" ] && [ -x "$VENV_PYTHON" ]; then
    if sudo "$DEV_REPO_PATH/tools/copy_unit.sh" --python_path "$VENV_PYTHON" --user "$REPO_OWNER" 2>&1 | tee -a /tmp/ota_update.log; then
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
        sudo systemctl enable --now "$timer_name" 2>&1 | tee -a /tmp/ota_update.log || true
    done
else
    log_status "info" "⚠ copy_unit.sh or venv python not found - skipping unit redeploy"
fi

log_status "info" "Scheduling service restart..."

# Schedule restart in background with sudo (needed for systemctl)
(sleep 5 && sudo systemctl restart rtkbase_web) &

log_status "success" "✅ Update completed successfully! Service will restart in 5 seconds."

exit 0
