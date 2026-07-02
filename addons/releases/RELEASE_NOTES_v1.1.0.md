# GeoMaxima v1.1.0 Release Notes

**Release Date**: January 16, 2025  
**Type**: Minor Release (New Feature)  
**Status**: Ready for Testing

## 🎯 Headline Feature

**Auto Survey-In**: Automatic 24-hour precise GNSS base station positioning with millimeter-level accuracy.

## 🚀 What's New

### Auto Survey-In System

A complete solution for determining highly accurate RTK base station coordinates through automated long-term GNSS surveying.

#### Key Capabilities

- **Automated Surveying**: 24-hour autonomous survey with hourly coordinate updates
- **Quality Filtering**: Processes only high-quality FIX solutions (Q=1, ratio ≥3.0, std ≤5cm)
- **Statistical Processing**: Modified Z-Score outlier detection with weighted averaging
- **Geoid Correction**: Converts ellipsoidal heights to orthometric (MSL) using .ggf grid files
- **Safe Updates**: Automatic configuration backups before each coordinate update
- **Restart Recovery**: State persistence allows seamless recovery after system restarts
- **Real-time Monitoring**: Web interface with progress tracking and quality metrics

#### Target Accuracy

| Duration | Horizontal | Vertical |
|----------|-----------|----------|
| 1 hour   | 10-20mm   | 20-40mm  |
| 6 hours  | 5-10mm    | 10-20mm  |
| 24 hours | **2-5mm** | **5-10mm** |

### Technical Implementation

#### Core Modules (7 new files)

1. **gnss_parser.py** - RTKLIB solution parsing
   - Parses `.pos` files from str2str_file service
   - Extracts FIX solutions with quality filtering
   - Computes position statistics

2. **position_estimator.py** - Statistical processing
   - Modified Z-Score outlier detection (MAD-based)
   - Weighted averaging with inverse variance
   - Convergence analysis

3. **geoid_corrector.py** - Height correction
   - .ggf grid file support (EGM96/EGM2008)
   - Bilinear interpolation
   - Ellipsoidal ↔ Orthometric conversion

4. **config_manager.py** - Configuration management
   - Safe RTKBase settings.conf updates
   - Automatic timestamped backups
   - Backup rotation (keeps 10 most recent)

5. **state_manager.py** - State persistence
   - JSON-based state file
   - Survey states: IDLE, RUNNING, PAUSED, COMPLETED, FAILED
   - Automatic recovery support

6. **survey_controller.py** - Main orchestrator
   - 24-hour survey loop
   - Hourly position updates
   - Background thread operation

7. **auto_survey_feature.py** - Flask API
   - REST endpoints for control
   - Web interface routes

#### Web Interface

**New Template**: `auto_survey.html`
- Real-time survey status monitoring
- Progress bar with time remaining
- Quality metrics display (ratio, satellites, accuracy)
- Current position with std devs
- Control buttons (Start, Stop, Reset)
- Auto-refresh every 30 seconds
- Responsive Bootstrap 4.6.1 design

#### REST API Endpoints

- `GET /geomaxima/survey` - Survey control page
- `GET /api/survey/status` - Current status
- `POST /api/survey/start` - Start new survey
- `POST /api/survey/stop` - Stop running survey
- `POST /api/survey/reset` - Reset state
- `GET/POST /api/survey/config` - Configuration
- `GET /api/survey/position` - Current antenna position

### Dependencies

**New Requirements** (added to `requirements.txt`):
- `numpy ≥1.19.0` - Array operations for position estimation
- `scipy ≥1.5.0` - Statistical functions for outlier detection

## 📝 Changes

### Modified Files
- `VERSION`: 1.0.2 → **1.1.0**
- `config.py`: Added `auto_survey: True` feature flag
- `templates/dashboard.html`: Added Auto Survey feature card with "Open Survey" button
- `CHANGELOG.md`: Full v1.1.0 changelog entry

### New Files
- `features/auto_survey/` - Complete feature package (7 modules)
- `features/auto_survey_feature.py` - Flask API routes
- `templates/auto_survey.html` - Web interface
- `requirements.txt` - Dependencies list
- `FEATURE_AUTO_SURVEY.md` - Implementation summary
- `TESTING_AUTO_SURVEY.md` - Testing guide
- `features/auto_survey/README.md` - Comprehensive documentation

## 🔧 Installation

### 1. Install Dependencies

```bash
cd ~/rtkbase/geomaxima
pip3 install -r requirements.txt
```

### 2. Deploy Update

**Option A: From GitHub Release (Recommended)**
```bash
cd /tmp
wget https://github.com/peshovp/GeoMaxima-BS/releases/download/v1.1.0/GeoMaxima-v1.1.0.zip
unzip GeoMaxima-v1.1.0.zip
cd GeoMaxima
./install_local.sh
```

**Option B: From Git**
```bash
cd ~/rtkbase
rm -rf geomaxima
git clone https://github.com/peshovp/GeoMaxima-BS.git geomaxima
cd geomaxima
pip3 install -r requirements.txt
./install_local.sh
```

### 3. Verify Installation

```bash
# Check dependencies
python3 -c "import numpy; import scipy; print('Dependencies OK')"

# Restart service
sudo systemctl restart rtkbase_web

# Check logs
sudo journalctl -u rtkbase_web -n 20
```

You should see: `Auto Survey-In routes registered`

### 4. Access Feature

Navigate to: **http://your-base-ip/geomaxima/survey**

## ✅ Testing Checklist

### Quick Test (1 hour)
- [ ] Feature loads in dashboard
- [ ] Survey page accessible
- [ ] Start 1-hour survey successfully
- [ ] Progress bar updates
- [ ] Epochs counter increases
- [ ] First update executes after 1 hour
- [ ] Stop/Reset functions work
- [ ] State persists across restart

### Full Production Survey (24 hours)
- [ ] Antenna firmly mounted with clear sky view
- [ ] RTKLIB obtaining consistent FIX solutions
- [ ] Start 24-hour survey
- [ ] Monitor periodically (every 2-4 hours)
- [ ] Hourly updates execute successfully
- [ ] Survey completes after 24 hours
- [ ] Final accuracy < 5mm horizontal
- [ ] Configuration updated in settings.conf
- [ ] Backups created in ~/rtkbase/backups/

## 📚 Documentation

### Comprehensive Guides

1. **Feature Documentation**: `features/auto_survey/README.md`
   - Architecture overview
   - API documentation
   - Usage examples
   - Best practices
   - Troubleshooting
   - Performance metrics

2. **Implementation Details**: `FEATURE_AUTO_SURVEY.md`
   - Technical architecture
   - Algorithms explained
   - Data structures
   - Integration notes

3. **Testing Guide**: `TESTING_AUTO_SURVEY.md`
   - Installation steps
   - Test procedures
   - Expected results
   - Troubleshooting common issues

## ⚠️ Important Notes

### Before Starting Survey

1. **Antenna Setup**
   - Mount antenna firmly on stable structure
   - Ensure clear 360° sky view (elevation mask ≥15°)
   - Check for nearby reflective surfaces (multipath)
   - Measure antenna height accurately

2. **System Checks**
   - Verify str2str_file service running
   - Confirm rover.pos file being written
   - Check FIX solutions are being obtained
   - Ensure system stability (no planned reboots)

3. **Environmental**
   - Avoid starting during severe weather
   - Check satellite availability (DOP values)
   - Consider local radio interference

### During Survey

- **DO NOT move antenna** during survey
- Monitor progress periodically
- Check quality metrics (ratio, satellites, std dev)
- Ensure system remains stable

### After Completion

- Verify final position accuracy
- Check RTKBase configuration updated correctly
- Restart str2str services to apply new coordinates
- Test base station with rover to confirm corrections

## 🐛 Known Limitations

- Requires numpy/scipy (not in base RTKBase)
- Geoid correction optional (less accurate without .ggf file)
- No real-time position plotting (table view only)
- Update interval not configurable via UI (1 hour fixed)

## 🔮 Future Enhancements

Potential improvements for future releases:

1. **Systemd Service**: Dedicated `rtkbase_survey.service` for background operation
2. **Email Notifications**: Alert on survey completion
3. **Real-time Charts**: JavaScript graphs for convergence visualization
4. **Multiple Geoid Models**: Support switching between models
5. **Export Reports**: PDF/HTML survey summary with quality plots
6. **PPK Mode**: Support post-processed kinematic surveys

## 🙏 Credits

- **RTKLIB**: Tomoji Takasu
- **RTKBase**: Stefal and contributors
- **GeoMaxima**: peshovp
- **Scientific Libraries**: NumPy, SciPy communities

## 📞 Support

- **GitHub Issues**: https://github.com/peshovp/GeoMaxima-BS/issues
- **Documentation**: `/home/peshovp/rtkbase/geomaxima/features/auto_survey/README.md`
- **Discussions**: https://github.com/peshovp/GeoMaxima-BS/discussions

## 📦 Upgrade from v1.0.2

This is a **minor version** upgrade (1.0.2 → 1.1.0) that adds new functionality without breaking existing features.

### What's Preserved
✅ All existing features (WireGuard VPN, Example Feature)
✅ Configuration files and settings
✅ Dashboard and UI
✅ API endpoints

### What's Added
✨ Auto Survey-In feature (optional, disabled by default in future)
✨ Dependencies: numpy, scipy
✨ New REST API endpoints
✨ New web interface template

### Migration Steps
1. Install numpy/scipy dependencies
2. Deploy v1.1.0 files
3. Restart rtkbase_web service
4. Feature automatically available

**No configuration changes required** - everything is backward compatible.

---

**Download**: [GeoMaxima-v1.1.0.zip](https://github.com/peshovp/GeoMaxima-BS/releases/download/v1.1.0/GeoMaxima-v1.1.0.zip)  
**Size**: ~35 KB  
**SHA256**: (will be generated on release)  

**Tested on**: Raspberry Pi 4, RTKBase 2.7.0, Debian 11  
**Python**: 3.9+  
**Status**: ✅ Feature Complete, Ready for Testing
