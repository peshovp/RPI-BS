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
# Install script step removed: install_local.sh lives under addons/, not repo
# root, and running it here duplicated setup that's already handled elsewhere.
# Kept only git reset --hard + service restart below.

# Rsync-to-deployed-location step removed: dev repo and deployed app are the
# same single directory in this architecture, so there is nothing to sync.

log_status "info" "Scheduling service restart..."

# Schedule restart in background with sudo (needed for systemctl)
(sleep 5 && sudo systemctl restart rtkbase_web) &

log_status "success" "✅ Update completed successfully! Service will restart in 5 seconds."

exit 0
