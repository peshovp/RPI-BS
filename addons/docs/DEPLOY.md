# GeoMaxima v1.2.0 - Deployment Guide

## 🎯 What's New in v1.2.0

### Auto Survey-In - Full RTKBase Integration
- ✅ **Auto-discovery** - Automatically finds RTKBase paths from settings.conf
- ✅ **File logging** - Automatically enables str2str_file service
- ✅ **RINEX conversion** - Converts raw UBX/RTCM logs to RINEX with convbin
- ✅ **SPP positioning** - Uses rnx2rtkp for Single Point Positioning
- ✅ **No manual config needed** - Everything works out-of-the-box!

### Other Improvements
- ✅ Fixed jQuery loading in Auto Survey page
- ✅ Template uses RTKBase base layout (navigation, footer)
- ✅ Installer auto-detects virtualenv and installs numpy/scipy correctly
- ✅ Creates required directories (/var/lib/rtkbase, work dirs)

---

## 📦 Fresh Installation (Recommended)

### Prerequisites
- RTKBase already installed and running
- Root/sudo access
- Internet connection

### Quick Install
```bash
# 1. Download GeoMaxima
cd ~
git clone https://github.com/peshovp/GeoMaxima-BS.git GeoMaxima
cd GeoMaxima

# 2. Run installer (auto-detects RTKBase and configures everything)
sudo ./install_local.sh
```

**That's it!** The installer will:
1. Find RTKBase installation automatically
2. Install numpy/scipy in RTKBase virtualenv
3. Copy all GeoMaxima files
4. Integrate with RTKBase web UI
5. Enable file logging for Auto Survey
6. Create state directories
7. Restart services

### Access
- Dashboard: `http://YOUR_IP/geomaxima`
- Auto Survey: `http://YOUR_IP/geomaxima/survey`
- WireGuard: `http://YOUR_IP/geomaxima/wireguard`

---

## 🔄 Upgrade from v1.1.0

If you already have GeoMaxima installed:

```bash
# 1. Pull latest code
cd ~/GeoMaxima
git pull

# 2. Re-run installer (safe, detects existing installation)
sudo ./install_local.sh
```

The installer will:
- Backup existing GeoMaxima installation
- Update all files
- Preserve your settings
- Configure new features (file logging, directories)

---

## 🧪 Testing Auto Survey

### 1. Check File Logging
```bash
# Should show "active"
systemctl status str2str_file.service

# If not active, installer will start it automatically when survey starts
```

### 2. Test Survey Start
1. Open `http://YOUR_IP/geomaxima/survey`
2. Click "Start Survey"
3. Set duration (e.g., 1 hour for testing)
4. Click "Start Survey" in modal

### 3. Monitor Progress
```bash
# Watch survey logs
sudo journalctl -u rtkbase_web -f | grep -i "survey\|rinex\|spp"

# Check raw data files
ls -lh ~/rtkbase/logs/

# Check work directory
ls -lh ~/rtkbase/geomaxima_survey/rinex/
```

### 4. Expected Workflow
```
[Survey Start]
  ↓
[Enable str2str_file service] → Logs raw GNSS data to ~/rtkbase/logs/
  ↓
[Every hour:]
  1. Find latest log file
  2. Convert to RINEX (convbin)
  3. Process SPP (rnx2rtkp)
  4. Parse positions
  5. Estimate mean with outlier rejection
  6. Apply geoid correction
  7. Update settings.conf
  8. Save state
  ↓
[After 24h: Survey Complete]
```

---

## 🔍 Troubleshooting

### Survey doesn't start
```bash
# Check logs
sudo journalctl -u rtkbase_web -n 50 | grep -i error

# Check file service
systemctl status str2str_file.service

# Check RTKLIB tools
which convbin rnx2rtkp

# Check permissions
ls -ld /var/lib/rtkbase
```

### No data files found
```bash
# Check if file service is logging
ls -lh ~/rtkbase/logs/

# If empty, start file service manually
sudo systemctl start str2str_file.service

# Wait 1 minute, check again
ls -lh ~/rtkbase/logs/
```

### RINEX conversion fails
```bash
# Test convbin manually
cd ~/rtkbase/logs
convbin -r ubx -o -n str2str_file_*.log

# Check output
ls -lh *.obs *.nav
```

### Dependencies missing
```bash
# Check virtualenv
source ~/rtkbase/venv/bin/activate
python -c "import numpy, scipy"

# If error, reinstall
pip install numpy scipy
```

---

## 📊 What Gets Created

### Directories
- `/var/lib/rtkbase/` - State files (survey_state.json)
- `~/rtkbase/geomaxima/` - GeoMaxima core files
- `~/rtkbase/geomaxima_survey/` - Work directory for RINEX files
- `~/rtkbase/web_app/templates/geomaxima/` - Web UI templates
- `~/rtkbase/web_app/static/geomaxima/` - Static files (CSS, JS)

### Services Modified
- `str2str_file.service` - Enabled and started (for data logging)
- `rtkbase_web.service` - Integrated with GeoMaxima

### Config Files Modified
- `~/rtkbase/settings.conf` - Position updated by Auto Survey
- `~/rtkbase/web_app/server.py` - GeoMaxima initialization added
- `~/rtkbase/web_app/templates/base.html` - GeoMaxima menu added

---

## 🎓 How Auto Survey Works

### Old Design (v1.0-1.1)
- Expected pre-existing RTKLIB .pos file
- **Problem:** RTKBase doesn't generate .pos files in base mode!

### New Design (v1.2.0)
1. **Auto-enables file logging** - Starts str2str_file to log raw data
2. **RINEX conversion** - Uses convbin to convert UBX/RTCM → RINEX
3. **SPP processing** - Uses rnx2rtkp for Single Point Positioning
4. **Statistical estimation** - Modified Z-Score outlier rejection
5. **Geoid correction** - EGM96 undulation → MSL height
6. **Config update** - Updates settings.conf with best estimate

### Target Accuracy (24-hour survey)
- Horizontal: < 1-2 meters (SPP, no corrections)
- Vertical: < 2-3 meters (SPP with geoid)

**Note:** For cm-level accuracy, use PPP or RTK with reference station!

---

## 🚀 Next Steps After Install

1. **Start a test survey (1 hour)**
   - Verify RINEX conversion works
   - Check SPP positioning
   - Monitor logs

2. **Run full 24-hour survey**
   - For best SPP accuracy
   - Clear sky view essential
   - Do not move antenna!

3. **Check final position**
   - View in dashboard
   - Compare with known coordinates
   - Verify in settings.conf

---

## 📞 Support

Issues? Check:
- GitHub Issues: https://github.com/peshovp/GeoMaxima-BS/issues
- RTKBase Docs: https://docs.rtkbase.org/
- RTKLIB Manual: http://www.rtklib.com/

---

**Version:** 1.2.0  
**Date:** 2025-12-21  
**Author:** GeoMaxima Team
