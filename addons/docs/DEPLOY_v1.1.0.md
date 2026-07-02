# Quick Deployment to BS-Aheloy (v1.1.0)

## Issue: Debian 12 Externally-Managed Python

Debian 12+ prevents `pip install` to system Python to avoid breaking OS packages.

### Solution: Use System Packages

Install numpy/scipy from Debian repositories instead:

```bash
ssh peshovp@192.168.1.14

# Install system packages (no venv needed)
sudo apt update
sudo apt install -y python3-numpy python3-scipy

# Verify installation
python3 -c "import numpy; import scipy; print('Dependencies OK')"
```

## Deployment Options

### Option A: Git Pull (Recommended for Active Development)

```bash
ssh peshovp@192.168.1.14
cd ~/rtkbase/geomaxima

# Pull latest changes
git pull origin master

# Copy templates and static files
sudo cp -r templates/* ~/rtkbase/web_app/templates/geomaxima/
sudo cp -r static/* ~/rtkbase/web_app/static/geomaxima/

# Clean Python cache
sudo find ~/rtkbase -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true

# Restart service
sudo systemctl restart rtkbase_web

# Check logs
sudo journalctl -u rtkbase_web -n 20
```

### Option B: GitHub Release ZIP

```bash
ssh peshovp@192.168.1.14

# Download release (retry if 404 - GitHub CDN delay)
cd /tmp
wget https://github.com/peshovp/GeoMaxima-BS/releases/download/v1.1.0/GeoMaxima-v1.1.0.zip

# If 404, wait 30 seconds and retry:
sleep 30
wget https://github.com/peshovp/GeoMaxima-BS/releases/download/v1.1.0/GeoMaxima-v1.1.0.zip

# Extract and install
unzip GeoMaxima-v1.1.0.zip
cd GeoMaxima
./install_local.sh
```

## Verification Steps

### 1. Check Dependencies

```bash
python3 -c "import numpy; print('NumPy version:', numpy.__version__)"
python3 -c "import scipy; print('SciPy version:', scipy.__version__)"
```

Expected output:
```
NumPy version: 1.24.x
SciPy version: 1.10.x
```

### 2. Check Service Status

```bash
sudo systemctl status rtkbase_web
```

Look for:
```
Active: active (running)
```

### 3. Check Logs

```bash
sudo journalctl -u rtkbase_web -n 30
```

Look for:
```
Loaded feature: auto_survey_feature
Auto Survey-In routes registered
```

### 4. Test Web Interface

```bash
# From your Windows machine
curl http://192.168.1.14/geomaxima/api/survey/status | jq
```

Expected:
```json
{
  "success": true,
  "status": {
    "survey_state": "idle",
    ...
  }
}
```

### 5. Access Dashboard

Open browser: **http://192.168.1.14/geomaxima**

You should see:
- Version: **v1.1.0**
- **Auto Survey** feature card with "Enabled" badge
- "Open Survey" button

Click "Open Survey" → **http://192.168.1.14/geomaxima/survey**

## Troubleshooting

### Dependencies Not Found

```bash
# Check if packages installed
dpkg -l | grep python3-numpy
dpkg -l | grep python3-scipy

# If missing, install:
sudo apt install -y python3-numpy python3-scipy
```

### Module Import Errors

```bash
# Check Python can find geomaxima
python3 -c "import sys; sys.path.insert(0, '/home/peshovp/rtkbase'); from geomaxima.features.auto_survey import SurveyController; print('OK')"
```

### Feature Not Loading

```bash
# Check files exist
ls -la ~/rtkbase/geomaxima/features/auto_survey/
ls -la ~/rtkbase/geomaxima/features/auto_survey_feature.py

# Check config
python3 << 'EOF'
import sys
sys.path.insert(0, '/home/peshovp/rtkbase')
from geomaxima import config
print('Features:', config.FEATURES)
EOF
```

### Templates Not Found

```bash
# Check templates copied
ls -la ~/rtkbase/web_app/templates/geomaxima/auto_survey.html

# If missing, copy manually:
sudo cp ~/rtkbase/geomaxima/templates/auto_survey.html ~/rtkbase/web_app/templates/geomaxima/
```

### Clear Cache and Restart

```bash
# Clean all Python cache
sudo find ~/rtkbase -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true
sudo find ~/rtkbase -name "*.pyc" -delete 2>/dev/null || true

# Restart with fresh state
sudo systemctl restart rtkbase_web

# Watch logs in real-time
sudo journalctl -u rtkbase_web -f
```

## Quick Test

Once deployed, test with 1-hour survey:

```bash
# Start test via API
curl -X POST http://192.168.1.14/geomaxima/api/survey/start \
  -H "Content-Type: application/json" \
  -d '{"target_hours": 1}'

# Check status
curl http://192.168.1.14/geomaxima/api/survey/status | jq

# Or use web interface at:
# http://192.168.1.14/geomaxima/survey
```

## System Package Versions

Debian 12 (Bookworm) includes:
- python3-numpy: 1.24.x
- python3-scipy: 1.10.x

These versions are **fully compatible** with GeoMaxima Auto Survey-In requirements (numpy ≥1.19.0, scipy ≥1.5.0).

## Why System Packages?

✅ **No venv needed** - simpler deployment  
✅ **OS-maintained** - automatic security updates  
✅ **Pre-compiled** - faster than pip builds  
✅ **Stable** - tested by Debian team  
✅ **No breaking system** - respects PEP 668  

---

**Next**: After successful deployment, proceed with 1-hour test survey, then 24-hour production survey.
