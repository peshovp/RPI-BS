# Quick Start: Testing Auto Survey-In v1.1.0

## Prerequisites

1. **Working RTKBase Installation**
   - RTKBase 2.7.0 or newer
   - RTKLIB str2str_file service running
   - GNSS receiver obtaining FIX solutions

2. **GeoMaxima v1.0.2 Installed**
   - Dashboard accessible at http://your-base/geomaxima

## Installation Steps

### 1. Install Dependencies

```bash
ssh peshovp@192.168.1.14
cd ~/rtkbase/geomaxima
pip3 install -r requirements.txt
```

This installs:
- numpy (array operations for position estimation)
- scipy (statistical functions for outlier detection)

### 2. Verify Installation

```bash
python3 -c "import numpy; import scipy; print('Dependencies OK')"
```

Expected output: `Dependencies OK`

### 3. Update GeoMaxima Files

Since you're developing locally, copy the new files:

```bash
# From your Windows dev machine (PowerShell)
cd E:\Projects\rtkbase-2.7.0
scp -r geomaxima/features/auto_survey peshovp@192.168.1.14:~/rtkbase/geomaxima/features/
scp geomaxima/features/auto_survey_feature.py peshovp@192.168.1.14:~/rtkbase/geomaxima/features/
scp geomaxima/templates/auto_survey.html peshovp@192.168.1.14:~/rtkbase/geomaxima/templates/
scp geomaxima/config.py peshovp@192.168.1.14:~/rtkbase/geomaxima/
scp geomaxima/VERSION peshovp@192.168.1.14:~/rtkbase/geomaxima/
scp geomaxima/requirements.txt peshovp@192.168.1.14:~/rtkbase/geomaxima/
```

Or use the installation script:

```bash
# On BS-Aheloy
cd ~/rtkbase
./geomaxima/install_local.sh
```

### 4. Restart RTKBase Web Service

```bash
sudo systemctl restart rtkbase_web
sudo systemctl status rtkbase_web
```

Check logs for errors:

```bash
sudo journalctl -u rtkbase_web -f
```

You should see:
```
Auto Survey-In routes registered
```

### 5. Access Web Interface

Navigate to: **http://192.168.1.14/geomaxima**

You should see:
- Dashboard updated to v1.1.0
- New "Auto Survey" feature card with "Open Survey" button
- Feature status: **Enabled**

Click "Open Survey" → http://192.168.1.14/geomaxima/survey

## Testing Procedure

### Test 1: UI Load
✅ Survey page loads without errors
✅ Status shows "IDLE"
✅ "Start Survey" button visible
✅ "How It Works" section displayed

### Test 2: Configuration Check
```bash
# Verify solution file exists
ls -lh ~/rtkbase/rover.pos
tail ~/rtkbase/rover.pos
```

You should see RTKLIB solution lines like:
```
2025/01/16 10:30:00.000   42.12345678   27.87654321   125.456  1  12  0.005  0.005  0.008  ...
```

### Test 3: Start Survey (Short Test)

1. Click "Start Survey" button
2. Set duration to **1 hour** (for quick test)
3. Click "Start Survey" in modal
4. Verify status changes to **RUNNING**
5. Progress bar appears
6. Auto-refresh activates (30 seconds)

### Test 4: Monitor Progress

Watch for:
- Progress percentage increasing
- "Epochs Processed" counter growing
- "Updates Performed" incrementing after 1 hour
- Current position appearing after first update

### Test 5: Stop/Reset

1. Click "Stop" button
2. Verify status changes to **PAUSED**
3. Click "Reset" button
4. Verify status returns to **IDLE**

### Test 6: API Endpoints

```bash
# Status
curl http://192.168.1.14/geomaxima/api/survey/status | jq

# Configuration
curl http://192.168.1.14/geomaxima/api/survey/config | jq

# Current position
curl http://192.168.1.14/geomaxima/api/survey/position | jq
```

### Test 7: State Persistence

1. Start survey
2. Wait 5 minutes
3. Restart web service: `sudo systemctl restart rtkbase_web`
4. Reload page
5. Verify survey resumed automatically

Check state file:
```bash
sudo cat /var/lib/rtkbase/survey_state.json | jq
```

### Test 8: Configuration Backup

After survey runs 1+ hour:

```bash
ls -lh ~/rtkbase/backups/
```

You should see backup files like:
```
settings.conf.20250116_103000
settings.conf.20250116_113000
```

### Test 9: Full 24-Hour Survey (Production)

⚠️ **Only do this when ready for production positioning!**

1. Verify antenna is firmly mounted
2. Check clear 360° sky view
3. Confirm RTKLIB obtaining consistent FIX solutions
4. Start survey with 24-hour duration
5. Monitor periodically (every 2-4 hours)
6. Check for completion after 24 hours
7. Verify final accuracy < 5mm horizontal

## Troubleshooting

### No FIX Solutions

**Check RTKLIB service:**
```bash
sudo systemctl status str2str_file
sudo journalctl -u str2str_file -n 50
```

**Check solution file:**
```bash
tail -f ~/rtkbase/rover.pos
```

### Import Errors

**Missing numpy/scipy:**
```bash
pip3 install --upgrade numpy scipy
```

**Module not found:**
```bash
# Check Python path
python3 -c "import sys; print(sys.path)"

# Verify files copied
ls -R ~/rtkbase/geomaxima/features/auto_survey/
```

### Feature Not Loading

**Check logs:**
```bash
sudo journalctl -u rtkbase_web -n 100
```

Look for:
```
Loaded feature: auto_survey_feature
Auto Survey-In routes registered
```

**Check config:**
```bash
python3 -c "import sys; sys.path.insert(0, '/home/peshovp/rtkbase'); from geomaxima import config; print(config.FEATURES)"
```

Should show: `{'auto_survey': True, ...}`

### Web Page Errors

**Clear browser cache** (Ctrl+F5)

**Check template copied:**
```bash
ls ~/rtkbase/web_app/templates/geomaxima/auto_survey.html
```

**Restart with clean cache:**
```bash
sudo find ~/rtkbase -name __pycache__ -type d -exec rm -rf {} +
sudo systemctl restart rtkbase_web
```

## Expected Results

### After 1-Hour Test
- 3600+ epochs processed (at 1Hz data rate)
- 1 update performed
- Position visible in UI
- Horizontal accuracy: 10-20mm
- Vertical accuracy: 20-40mm

### After 24-Hour Survey
- 86400+ epochs processed
- 24 updates performed
- Final position stored in settings.conf
- Horizontal accuracy: 2-5mm
- Vertical accuracy: 5-10mm

## Success Indicators

✅ Feature loads without errors
✅ Web UI accessible and functional
✅ Survey starts and runs in background
✅ State persists across restarts
✅ Hourly updates execute successfully
✅ Configuration backups created
✅ Final position written to settings.conf
✅ RTKBase continues operating normally

## Next Steps

After successful testing:

1. **Production Survey**
   - Plan 24-48 hour survey during stable weather
   - Ensure antenna firmly mounted
   - Monitor first few hours for issues

2. **Geoid Model** (Optional)
   - Download EGM2008 .ggf file
   - Update controller initialization
   - Improves height accuracy

3. **Documentation**
   - Add to RTKBase wiki
   - Share results with community
   - Document any site-specific issues

4. **Version Control**
   - Commit all changes
   - Tag v1.1.0
   - Push to GitHub
   - Create release

## Contact

For issues or questions:
- GitHub: https://github.com/peshovp/GeoMaxima-BS/issues
- Feature docs: `/home/peshovp/rtkbase/geomaxima/features/auto_survey/README.md`

---

**Testing Duration**: 1-2 hours (short test) or 24+ hours (full survey)  
**Risk Level**: Low (read-only until config update, backups created)  
**Recommended**: Test with 1-hour survey first, then proceed to 24-hour production survey
