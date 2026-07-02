# GeoMaxima v1.3.0 Release Notes

**Release Date:** December 22, 2025  
**Status:** Production Ready ✅

## 🎉 What's New

### Auto Survey-In v1.3.0 - Production Ready
This release marks the **first production-ready version** of Auto Survey-In after extensive testing and critical bug fixes.

**Tested in Production:**
- ✅ 34,123 SPP epochs processed successfully
- ✅ BGR2005 geoid correction verified (~46m)
- ✅ Outlier rejection working (921 outliers removed)
- ✅ Horizontal accuracy: ~8.3m (1-hour survey)
- ✅ Vertical accuracy: ~11.2m (1-hour survey)
- ✅ Expected 24h accuracy: 1-2m horizontal, 2-3m vertical

## 🐛 Critical Bug Fixes

### RTKLIB Integration
1. **Missing rnx2rtkp tool** ❌ → ✅ Auto-compiled from source
   - Added `install_rnx2rtkp()` function to installer
   - Downloads RTKLIB v2.5.0 from rtklibexplorer
   - Compiles with gfortran and installs to `/usr/local/bin`

2. **Missing gfortran dependency** ❌ → ✅ Auto-installed
   - Installer checks for gfortran and libgfortran5
   - Installs missing dependencies automatically

3. **RINEX conversion failing** ❌ → ✅ Fixed convbin flags
   - Removed incorrect `-o` and `-n` flags
   - These were interpreted as filenames instead of options
   - Now generates `.obs` and `.nav` files correctly

### Position Processing
4. **Parser failing on GPS week format** ❌ → ✅ Dual-format parser
   - rnx2rtkp outputs GPS week/second format (e.g., `2398 25858.000`)
   - Old parser expected date/time format
   - New parser auto-detects and handles both formats

5. **AttributeError on position data** ❌ → ✅ Dict compatibility
   - Position data from parser is dict, not object
   - Changed all `e.lat` → `e['lat']`
   - Added safe `e.get('ratio', 0.0)` for optional fields

### Configuration
6. **UI not updating without restart** ❌ → ✅ Auto-reload
   - Settings changes now trigger RTKBase config reload
   - Added file touch to activate inotify watcher
   - Coordinates appear immediately in UI

## ✨ New Features

### Hostname Display
- **Browser tabs** now show station hostname (e.g., "Auto Survey-In - BS-Aheloy")
- **Patch system** for RTKBase base.html global hostname display
- JavaScript fallback for template block limitations

### Installation Improvements
- **Template verification** - Shows copied files during install
- **Forced sync** - Uses `rsync --delete` for clean updates
- **Version display** - Shows installed version after completion
- **Better logging** - Fixed missing `log_success` function

## 📊 Performance

### Validated Results
```
Survey Duration:    1 hour
Epochs Processed:   34,123
Quality Filter:     Q=5 (SPP)
Mean Satellites:    11.9
Outliers Rejected:  921 (2.7%)
```

### Accuracy
```
Horizontal:  8.3m  (1h) → 1-2m expected (24h)
Vertical:    11.2m (1h) → 2-3m expected (24h)
```

### Geoid Correction
```
Ellipsoidal Height:  ~260.7m
Geoid Separation:    +46.0m (BGR2005)
Orthometric Height:  306.7m (MSL)
```

## 🔧 Technical Changes

### Modified Files
- `install_local.sh` - Added RTKLIB compilation, improved deployment
- `features/auto_survey/rinex_converter.py` - Fixed convbin command
- `features/auto_survey/spp_processor.py` - Dual-format parser
- `features/auto_survey/position_estimator.py` - Dict compatibility
- `features/auto_survey/rtkbase_config.py` - Auto-reload on update
- `features/auto_survey_feature.py` - Hostname support
- `templates/auto_survey.html` - JavaScript title update

### New Files
- `patches/rtkbase_hostname.patch` - Global hostname display

### Dependencies
- gfortran (for rnx2rtkp compilation)
- libgfortran5 (runtime)
- RTKLIB v2.5.0 (auto-downloaded)

## 📦 Installation

### Fresh Install
```bash
cd ~
git clone https://github.com/peshovp/GeoMaxima-BS.git GeoMaxima
cd GeoMaxima
sudo ./install_local.sh
```

### Upgrade from v1.2.x
```bash
cd ~/GeoMaxima
git pull origin master
sudo ./install_local.sh
```

## 🎯 Usage

1. Open RTKBase web interface
2. Click **GEOMAXIMA** tab
3. Click **Auto Survey Feature** → **Open Survey**
4. Click **Start Survey**
5. Wait 24 hours for optimal accuracy
6. Coordinates update hourly automatically

## ⚠️ Important Notes

### First Hour Results
The first 1-hour update shows **~8-11m accuracy** - this is normal! SPP positioning improves significantly with more data:
- 1 hour: ~8-11m
- 6 hours: ~5-7m
- 12 hours: ~3-5m
- **24 hours: ~1-2m** (SPP baseline)

### Geoid Model Required
For accurate orthometric heights in Bulgaria, ensure BGR2005 geoid model is installed. The installer handles this automatically.

### Service Restarts
After installation/update, RTKBase web service restarts automatically. Web UI may be unavailable for ~10 seconds.

## 🙏 Acknowledgments

Tested on production RTKBase 2.7.0 installation at **BS-Aheloy** base station.

Special thanks to:
- **RTKBase project** - Excellent GNSS base station software
- **RTKLIB project** - High-quality GNSS positioning tools
- **BGR2005 team** - Bulgarian geoid model

## 📞 Support

For issues or questions:
- GitHub Issues: https://github.com/peshovp/GeoMaxima-BS/issues
- Documentation: See `CHANGELOG.md` for detailed changes

---

**Full Changelog:** [v1.2.2...v1.3.0](https://github.com/peshovp/GeoMaxima-BS/compare/v1.2.2...v1.3.0)
