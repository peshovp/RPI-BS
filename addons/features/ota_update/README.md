# OTA Update Manager

Web-based Over-The-Air update system for GeoMaxima deployments.

## 🎯 Purpose

Enable remote software updates without requiring SSH/terminal access - ideal for:
- Remote GNSS base stations
- Distributed deployments
- Field installations
- Non-technical operators

## ✨ Features

### 1. Version Information
- Current installed version
- Active git branch
- Commit hash and message
- Installation date
- Uncommitted changes detection

### 2. Update Checking
- Fetch latest from GitHub origin
- Compare local vs remote commits
- Show number of commits behind
- Display changelog with new commits
- Network timeout handling (30 seconds)

### 3. One-Click Updates
**Process:**
1. Stash any local changes (auto-backup)
2. Fetch latest from GitHub
3. Pull updates for current branch
4. Run `install_local.sh` script
5. Restart `rtkbase_web` service
6. Show detailed update log

**Safety features:**
- Automatic git stash before update
- Dry-run capability
- Detailed error logging
- Rollback via stashed changes
- Service restart validation

### 4. Git History
- View last 10-100 commits
- Commit hash, author, date, message
- Scrollable log interface

## 🌐 Web Interface

**URL:** `http://station-ip/geomaxima/update`

### Current Version Card
```
Version: 1.3.1
Branch: master
Commit: cc0f11a
Date: 2025-12-22 15:30:45 +0200
Message: Fix JavaScript duplicate code in auto_survey.html
```

### Update Controls
- **Check for Updates** - Query GitHub for new commits
- **Install Update** - One-click update process
- **Update Log** - Real-time progress display

### Recent Commits
Scrollable list showing:
- Commit hash (short)
- Author and date
- Commit message

## 📡 API Endpoints

### GET `/geomaxima/api/update/version`
Get current version information.

**Response:**
```json
{
  "success": true,
  "version": {
    "version": "1.3.1",
    "branch": "master",
    "commit": "cc0f11a1234...",
    "commit_short": "cc0f11a",
    "commit_date": "2025-12-22 15:30:45 +0200",
    "commit_message": "Fix JavaScript...",
    "has_uncommitted_changes": false,
    "repo_path": "/home/peshovp/rtkbase/geomaxima"
  }
}
```

### POST `/geomaxima/api/update/check`
Check for available updates from GitHub.

**Response (updates available):**
```json
{
  "success": true,
  "updates": {
    "updates_available": true,
    "commits_behind": 3,
    "local_commit": "abc1234",
    "remote_commit": "xyz9876",
    "changelog": "xyz9876 Add feature X\n...",
    "branch": "master"
  }
}
```

**Response (up to date):**
```json
{
  "success": true,
  "updates": {
    "updates_available": false,
    "message": "Already up to date",
    "branch": "master"
  }
}
```

### POST `/geomaxima/api/update/perform`
Perform OTA update (takes 2-5 minutes).

**Request:**
```json
{
  "restart_service": true  // Optional, default: true
}
```

**Response (success):**
```json
{
  "success": true,
  "timestamp": "2025-12-22T15:45:30",
  "log": "Stashing local changes...\n✓ Local changes stashed\n...",
  "new_version": {
    "version": "1.4.0",
    "commit_short": "xyz9876"
  }
}
```

**Response (error):**
```json
{
  "success": false,
  "error": "Update failed: ...",
  "log": "Step 1...\n❌ Error at step 3"
}
```

### GET `/geomaxima/api/update/status`
Get current update operation status.

**Response:**
```json
{
  "success": true,
  "status": {
    "update_in_progress": false,
    "last_update": {
      "success": true,
      "timestamp": "2025-12-22T15:45:30",
      "new_version": {...}
    }
  }
}
```

### GET `/geomaxima/api/update/log?limit=20`
Get recent git commit history.

**Parameters:**
- `limit` - Number of commits (1-100, default: 20)

**Response:**
```json
{
  "success": true,
  "commits": [
    {
      "hash": "full_hash...",
      "hash_short": "cc0f11a",
      "author": "Author Name",
      "author_email": "author@email.com",
      "date": "2025-12-22 15:30:45 +0200",
      "message": "Commit message"
    }
  ]
}
```

## 🔧 Technical Details

### UpdateController Class

**Location:** `features/ota_update/update_controller.py`

**Key Methods:**

#### `__init__(repo_path=None)`
Auto-detects repository path if not provided.

**Detection order:**
1. `/home/peshovp/rtkbase/geomaxima` (production)
2. `/opt/geomaxima`
3. Script directory (development)

#### `get_current_version() -> Dict`
Returns current installation details using git commands.

#### `check_for_updates() -> Dict`
Fetches from origin and compares local vs remote HEAD.

**Timeout:** 30 seconds for network operations.

#### `perform_update(restart_service=True) -> Dict`
Full update process with safety measures.

**Steps:**
1. Check update lock (prevent concurrent updates)
2. `git stash push` - Backup local changes
3. `git fetch origin` - Get latest metadata
4. `git pull origin <branch>` - Pull updates
5. `sudo bash install_local.sh` - Run installer
6. `sudo systemctl restart rtkbase_web` - Restart service

**Timeouts:**
- `git fetch`: 30 seconds
- `git pull`: 60 seconds
- `install_local.sh`: 300 seconds (5 minutes)

#### `get_git_log(limit=20) -> List[Dict]`
Returns formatted commit history.

### Thread Safety
- `threading.Lock()` prevents concurrent updates
- `update_in_progress` flag for status checking
- Last update status stored for reference

### Error Handling
- Network timeouts → User-friendly messages
- Git errors → Detailed logging
- Script failures → Return stderr output
- Partial updates → Rollback via stash

## 🚨 Safety Considerations

### Before Update
- ✅ Automatic git stash of local changes
- ✅ Check for uncommitted changes
- ✅ Verify network connectivity

### During Update
- ✅ Thread lock prevents concurrent updates
- ✅ Timeout protection (max 5 minutes)
- ✅ Detailed logging of each step
- ✅ Error capture and reporting

### After Update
- ✅ Automatic service restart
- ✅ Version verification
- ✅ Update log preservation
- ✅ Stashed changes available for recovery

### Recovery from Failed Update
```bash
# View stashed changes
cd /home/peshovp/rtkbase/geomaxima
git stash list

# Restore last stash
git stash pop

# Or specific stash
git stash apply stash@{0}
```

## 📋 Requirements

### System
- Git installed and configured
- Internet connectivity to GitHub
- Sudo access for service control

### Permissions
User running rtkbase_web must have:
- Read access to repository
- Sudo rights for:
  - `systemctl restart rtkbase_web`
  - `bash install_local.sh`

**Recommended sudoers entry:**
```
www-data ALL=(ALL) NOPASSWD: /bin/systemctl restart rtkbase_web
www-data ALL=(ALL) NOPASSWD: /home/peshovp/rtkbase/geomaxima/install_local.sh
```

### Network
- Outbound HTTPS (443) to github.com
- DNS resolution for github.com
- Firewall allows git protocol

## 🎨 UI Components

### Color Coding
- **Purple gradient** - Normal version card
- **Pink gradient** - Uncommitted changes warning
- **Green alert** - System up to date
- **Yellow alert** - Updates available
- **Blue progress** - Update in progress
- **Red alert** - Update error

### User Warnings
Before update, displays:
```
⚠ Warning:
- Update process takes 2-5 minutes
- Web interface will restart automatically
- Don't close browser during update
```

### Auto-reload
After successful update:
- Shows success message
- 5-second countdown
- Automatic page reload
- New version displayed

## 🔍 Troubleshooting

### "Could not find GeoMaxima repository"
**Cause:** Auto-detection failed.

**Solution:**
```python
# In config.py, add:
FEATURES = {
    "ota_update": {
        "enabled": True,
        "repo_path": "/custom/path/to/geomaxima"
    }
}
```

### "Network timeout - check internet connection"
**Cause:** GitHub unreachable within 30 seconds.

**Check:**
```bash
ping github.com
curl -I https://github.com
git ls-remote https://github.com/peshovp/GeoMaxima-BS.git
```

### "Update failed: Permission denied"
**Cause:** Missing sudo permissions.

**Solution:** Add sudoers entry (see Requirements section).

### "Patch failed (may already be applied)"
**Cause:** RTKBase structure changed.

**Action:** Update is still applied, but hostname patch skipped (non-critical).

### Update hangs at "Running install script..."
**Timeout:** Max 5 minutes, then fails.

**Check install script:**
```bash
sudo bash /home/peshovp/rtkbase/geomaxima/install_local.sh
# Watch for hanging prompts or errors
```

## 📊 Monitoring

### Check Update Status
```bash
# View last update log
journalctl -u rtkbase_web | grep -i "update"

# Check service status
systemctl status rtkbase_web

# Verify current version
cd /home/peshovp/rtkbase/geomaxima
git log -1
```

### Audit Trail
All updates logged to:
- `journalctl` (systemd journal)
- Update log in UI (last operation)
- Git reflog (branch history)

## 🎯 Use Cases

### 1. Bug Fix Deployment
```
Developer pushes fix → GitHub
Station checks for updates → Shows 1 new commit
Operator clicks "Install Update" → Auto-deployed
Service restarts → Fix active
```

### 2. Feature Rollout
```
New feature merged to master → GitHub
Multiple stations check → All show update available
Staged rollout: Update station 1, test, update others
Version tracking via commit hash
```

### 3. Emergency Patch
```
Critical security fix → Pushed to GitHub
Remote operator notified → Logs in to web UI
One-click update → Applied in 3 minutes
No site visit required
```

## 🔐 Security

### Authentication
- Uses RTKBase web authentication
- No additional login required
- Same security as rest of web UI

### Authorization
- Only authenticated users see update page
- Sudo commands whitelisted via sudoers
- No arbitrary command execution

### Network Security
- HTTPS to GitHub (encrypted)
- No incoming connections required
- Standard git protocol

### Code Verification
- Updates from trusted GitHub repository
- Branch protection recommended
- Commit signatures optional

## 📝 Best Practices

1. **Test updates** on development station first
2. **Schedule updates** during low-traffic periods
3. **Monitor logs** after update
4. **Backup configuration** before major updates
5. **Document** custom changes (will be stashed)
6. **Network reliability** - don't update during storms
7. **Remote access** - have backup SSH access

## 🚀 Future Enhancements

Planned features:
- [ ] Rollback to previous version (1-click)
- [ ] Update scheduling (cron-based)
- [ ] Email notifications on update completion
- [ ] Changelog preview before update
- [ ] Selective file update (not full pull)
- [ ] Version pinning (stay on specific commit)
- [ ] Update history (last 10 updates)
- [ ] Bandwidth usage estimation

## 📄 License

Same as GeoMaxima project (see main LICENSE file).

---

**Developed for:** GeoMaxima RTKBase Extension  
**Version:** 1.0 (Initial Release - 2025-12-22)  
**Author:** GeoMaxima Team
