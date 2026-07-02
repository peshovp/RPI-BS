# Testing OTA Update Manager on BS-Aheloy

## Quick Test on Production Station

### 1. SSH to BS-Aheloy
```bash
ssh peshovp@bs-aheloy-ip
cd ~/rtkbase/geomaxima
```

### 2. Pull Latest Code (Manual This Time)
```bash
git pull origin master
sudo ./install_local.sh
```

This will:
- Pull new OTA Update feature code
- Install update_controller.py and routes
- Move templates to geomaxima/ subfolder
- Restart rtkbase_web service

### 3. Verify Service Restart
```bash
sudo systemctl status rtkbase_web
```

Look for:
```
● rtkbase_web.service - RTKBase Web Server
   Active: active (running)
   ...
   OTA Update feature routes registered
```

### 4. Test Web Interface
Open browser: `http://bs-aheloy-ip/geomaxima/update`

Should see:
- **Current Version Card** (purple gradient)
  - Version: 1.3.1
  - Branch: master
  - Current commit and date
  
- **Update Controls**
  - "Check for Updates" button
  - Auto-checks 2 seconds after page load

### 5. Test Update Check
Click "Check for Updates"

**Expected Results:**

**If you're up to date:**
```
✓ System is up to date
```

**If updates available (after you make changes):**
```
Updates Available: X new commits
[Commit list displayed]
"Install Update" button appears
```

### 6. Test Full Update Cycle (After Creating Test Commit)

On development PC, create a test commit:
```bash
# Make small change
echo "# Test OTA" >> README.md
git add README.md
git commit -m "Test OTA update mechanism"
git push origin master
```

On BS-Aheloy web UI:
1. Click "Check for Updates" → Should show 1 commit behind
2. Click "Install Update"
3. Confirm dialog
4. Watch progress:
   - "Starting update..."
   - Shows update log in real-time
   - "Update completed successfully!"
   - Page reloads after 5 seconds
5. Verify new version displayed

### 7. Verify Update Applied
```bash
cd ~/rtkbase/geomaxima
git log -1
# Should show your test commit
```

### 8. Check Survey Still Running
Your 24-hour survey should still be running:
```bash
# Check survey status
curl -s http://localhost:5000/geomaxima/api/survey/status | python3 -m json.tool

# Check file logging (should be active during survey)
sudo systemctl status str2str_file.service
```

## Expected Timeline

```
[00:00] Pull code manually via SSH
[00:30] install_local.sh completes
[01:00] Service restarted, web UI available
[02:00] Test update check - shows up to date
[05:00] Make test commit on dev PC
[06:00] Check updates - shows 1 behind
[07:00] Click Install Update
[07:30] Update starts (stash, fetch, pull)
[09:00] Install script runs
[11:00] Service restarts
[11:30] Page reloads with new version
[12:00] Verify update applied ✅
```

## Troubleshooting

### "OTA Update feature not initialized"
**Check:**
```bash
grep -i "ota_update" ~/rtkbase/geomaxima/config.py
# Should show: "ota_update": True
```

### "Could not find GeoMaxima repository"
**Check:**
```bash
cd ~/rtkbase/geomaxima
ls -la .git
# Should exist
```

### Update button does nothing
**Check browser console:**
```
F12 → Console tab → Look for JavaScript errors
```

**Check service logs:**
```bash
sudo journalctl -u rtkbase_web -f
# Click update button and watch logs
```

### "Permission denied" during update
**Check sudo permissions:**
```bash
sudo -l
# Should show NOPASSWD entries or prompt for password
```

**Fix (if needed):**
```bash
# Add to /etc/sudoers.d/rtkbase
echo "peshovp ALL=(ALL) NOPASSWD: /bin/systemctl restart rtkbase_web" | sudo tee -a /etc/sudoers.d/rtkbase
echo "peshovp ALL=(ALL) NOPASSWD: /home/peshovp/rtkbase/geomaxima/install_local.sh" | sudo tee -a /etc/sudoers.d/rtkbase
sudo chmod 0440 /etc/sudoers.d/rtkbase
```

## Success Criteria

✅ Web UI loads at `/geomaxima/update`  
✅ Current version displayed correctly  
✅ "Check for Updates" button works  
✅ Update detection accurate (GitHub connectivity)  
✅ Full update cycle completes (with test commit)  
✅ Service auto-restarts after update  
✅ Page auto-reloads with new version  
✅ Auto Survey continues uninterrupted  
✅ No errors in service logs  

## Next Steps After Successful Test

1. **Remove test commit** (if desired):
   ```bash
   git revert HEAD
   git push origin master
   # Then update via web UI to revert
   ```

2. **Monitor survey completion:**
   - 24 hours from start
   - File logging auto-stops
   - Position calculated and applied

3. **Use OTA Update for future deployments:**
   - No more SSH required!
   - Update from any device with browser
   - Perfect for remote stations

## Security Note

Currently running as `peshovp` user. For production:
- Consider dedicated service user
- Restrict sudo permissions to specific commands
- Enable firewall rules
- Use HTTPS with valid certificate
- Strong authentication required

---

**Ready to test?** → SSH to BS-Aheloy and start with step 1! 🚀
