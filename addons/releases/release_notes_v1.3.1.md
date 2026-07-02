# v1.3.1 - Critical Disk Management Fix

## 🚨 CRITICAL UPDATE - Prevents Disk Space Exhaustion

**This is a MANDATORY update for all production deployments!**

### What's Fixed

File logging now **automatically stops** after survey completion, preventing disk space exhaustion from continuous GNSS data accumulation.

**Problem Solved:**
- ❌ Before: 24h survey + 7 days = ~12GB disk usage (logging never stops)
- ✅ After: 24h survey = 1.8GB (auto-stopped)

### New Features

- **Automatic logging stop** after survey completion or manual stop
- **Manual logging controls** in UI (Start/Stop buttons)
- **API endpoints** for programmatic logging control:
  - `POST /api/survey/logging/start`
  - `POST /api/survey/logging/stop`

### Changes

- Survey finalization automatically stops `str2str_file.service`
- Manual survey stop also stops file logging
- Enhanced UI warnings about disk space management
- Improved logging messages

### Technical Details

**Modified Files:**
- `features/auto_survey/survey_controller.py` - Added `_stop_file_logging()`
- `features/auto_survey_feature.py` - New API endpoints
- `templates/auto_survey.html` - Manual control buttons

**Typical Data Rates:**
- UBX logging: ~75MB/hour
- 24h survey: ~1.8GB
- Without auto-stop: Disk fills continuously ⚠️

### Upgrade Instructions

```bash
cd ~/GeoMaxima
git pull origin master
sudo ./install_local.sh
```

### Validation

Tested on BS-Aheloy production station:
- ✅ Logging starts with survey
- ✅ Logging stops after completion
- ✅ Manual controls working
- ✅ API endpoints functional

---

**Full Changelog:** https://github.com/peshovp/GeoMaxima-BS/blob/master/CHANGELOG.md

**Previous Release:** [v1.3.0](https://github.com/peshovp/GeoMaxima-BS/releases/tag/v1.3.0) - Production Ready Auto Survey-In
