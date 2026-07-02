# Auto Survey-In Feature

Automatic 24-hour precise base station positioning for RTKBase.

## Overview

The Auto Survey-In feature determines highly accurate base station coordinates by collecting and analyzing GNSS FIX solutions over an extended period (typically 24 hours). This ensures millimeter-level positioning accuracy for your RTK base station.

## How It Works

### 1. Data Collection
- Monitors RTKLIB solution file (`rover.pos`) continuously
- Extracts only high-quality FIX solutions (Q=1)
- Filters by quality metrics:
  - Ambiguity ratio ≥ 3.0
  - 3D position std dev ≤ 5cm
  - Minimum 5 satellites

### 2. Statistical Processing
- **Outlier Rejection**: Modified Z-Score (MAD-based) removes atmospheric/multipath outliers
- **Weighted Averaging**: Inverse variance weighting based on solution quality
- **Convergence Analysis**: Hourly position updates show stability

### 3. Geoid Correction
- Converts ellipsoidal height (GNSS) to orthometric height (MSL)
- Uses .ggf grid file (EGM96/EGM2008) for accurate local geoid
- Critical for correct height reference

### 4. Configuration Update
- Updates RTKBase `settings.conf` with precise coordinates
- Creates automatic backups before each update
- Hourly updates minimize service interruption

### 5. State Persistence
- Saves progress to `/var/lib/rtkbase/survey_state.json`
- Recovers automatically after system restarts
- Maintains survey continuity

## Architecture

```
features/auto_survey/
├── __init__.py              # Package exports
├── survey_controller.py     # Main orchestration
├── gnss_parser.py           # RTKLIB solution parsing
├── position_estimator.py    # Statistical position estimation
├── geoid_corrector.py       # Geoid height correction
├── config_manager.py        # RTKBase configuration updates
└── state_manager.py         # State persistence
```

### Key Classes

#### `SurveyController`
Main orchestrator - manages 24-hour survey loop with hourly updates.

```python
controller = SurveyController(
    solution_file="/home/peshovp/rtkbase/rover.pos",
    state_file="/var/lib/rtkbase/survey_state.json",
    settings_file="/home/peshovp/rtkbase/settings.conf",
    geoid_file="/path/to/geoid.ggf"  # Optional
)

controller.start_survey(target_hours=24)
status = controller.get_status()
controller.stop_survey()
```

#### `GNSSDataParser`
Parses RTKLIB `.pos` files and extracts quality epochs.

```python
parser = GNSSDataParser(min_ratio=3.0, max_std_3d=0.05)
epochs = parser.parse_pos_file("rover.pos")
stats = parser.compute_statistics(epochs)
```

#### `PositionEstimator`
Robust position estimation with outlier rejection.

```python
estimator = PositionEstimator(outlier_threshold=3.5, min_epochs=100)
estimate = estimator.estimate_position(epochs)

print(f"Position: {estimate.lat:.8f}°, {estimate.lon:.8f}°")
print(f"Accuracy: {estimate.horizontal_std_meters*1000:.1f}mm")
```

#### `GeoidCorrector`
Geoid height interpolation from .ggf grid files.

```python
geoid = GeoidCorrector("/path/to/egm2008.ggf")
h_ortho = geoid.ellipsoidal_to_orthometric(lat, lon, h_ellipsoid)
```

#### `ConfigManager`
Safe RTKBase configuration management.

```python
config = ConfigManager("/home/peshovp/rtkbase/settings.conf")
config.set_antenna_position(lat, lon, height)
current = config.get_current_position()
```

#### `StateManager`
Survey state persistence and recovery.

```python
state = StateManager("/var/lib/rtkbase/survey_state.json")
state.start_survey(target_hours=24)
state.update_progress(position, position_std, num_epochs, quality_metrics)
state.complete_survey(final_position)
```

## API Endpoints

### GET `/geomaxima/survey`
Web interface for survey control and monitoring.

### GET `/geomaxima/api/survey/status`
Get current survey status.

**Response:**
```json
{
  "success": true,
  "status": {
    "survey_state": "running",
    "start_time": "2024-01-15T10:00:00Z",
    "target_hours": 24,
    "completed_hours": 12.5,
    "progress_percent": 52.1,
    "num_epochs": 45000,
    "current_position": {
      "lat": 42.12345678,
      "lon": 27.87654321,
      "height": 125.456
    },
    "position_std": {
      "std_h_meters": 0.003,
      "std_height": 0.005
    },
    "quality_metrics": {
      "mean_ratio": 5.8,
      "mean_sats": 12.3,
      "rejected_epochs": 237
    }
  }
}
```

### POST `/geomaxima/api/survey/start`
Start new survey session.

**Request:**
```json
{
  "target_hours": 24
}
```

**Response:**
```json
{
  "success": true,
  "message": "Survey started (24h)"
}
```

### POST `/geomaxima/api/survey/stop`
Stop running survey.

### POST `/geomaxima/api/survey/reset`
Reset survey state to idle.

### GET/POST `/geomaxima/api/survey/config`
Get or update survey configuration.

**GET Response:**
```json
{
  "success": true,
  "config": {
    "target_hours": 24,
    "update_interval_hours": 1,
    "parser": {
      "min_ratio": 3.0,
      "max_std_3d": 0.05
    },
    "estimator": {
      "outlier_threshold": 3.5,
      "min_epochs": 100
    },
    "geoid_loaded": true
  }
}
```

## Usage

### Web Interface

1. Navigate to: `http://your-base-ip/geomaxima/survey`
2. Verify antenna is firmly mounted with clear sky view
3. Click "Start Survey"
4. Select duration (default: 24 hours)
5. Monitor progress and quality metrics
6. Wait for completion (or stop early if needed)

### Command Line

```python
from geomaxima.features.auto_survey import SurveyController

controller = SurveyController()
controller.start_survey(target_hours=24)

# Check status
status = controller.get_status()
print(f"Progress: {status['progress_percent']:.1f}%")
print(f"Position: {status['current_position']}")
```

## Installation

### Requirements

```bash
pip install numpy scipy
```

Or using GeoMaxima requirements:

```bash
cd /home/peshovp/rtkbase/geomaxima
pip install -r requirements.txt
```

### Geoid Model (Optional but Recommended)

Download EGM2008 geoid model for accurate orthometric heights:

```bash
# Download from RTKLIB resources
wget http://www.unavco.org/software/geodetic-utilities/geoid/geoid.php
# Or use local EGM96 model
```

Update survey controller initialization:

```python
controller = SurveyController(
    geoid_file="/path/to/egm2008.ggf"
)
```

## Best Practices

### Before Starting Survey

1. **Antenna Setup**
   - Mount antenna firmly on stable structure
   - Ensure clear 360° sky view (elevation mask ≥15°)
   - Check for nearby reflective surfaces (multipath)
   - Measure antenna height accurately

2. **RTKLIB Configuration**
   - Verify str2str_file service is running
   - Check rover.pos file is being written
   - Confirm FIX solutions are being obtained

3. **Environmental Conditions**
   - Avoid starting during severe weather
   - Check satellite availability (DOP values)
   - Consider local radio interference

### During Survey

1. **Do NOT move antenna**
2. Monitor survey progress periodically
3. Check quality metrics (ratio, satellites, std dev)
4. Ensure system stability (no reboots if possible)

### After Completion

1. Verify final position accuracy (< 5mm horizontal recommended)
2. Check RTKBase configuration updated correctly
3. Restart str2str services to apply new coordinates
4. Test base station with rover to confirm corrections

## Troubleshooting

### No FIX Solutions

**Problem:** Survey shows 0 epochs after hours of running.

**Solutions:**
- Check RTKLIB is receiving corrections (if in PPK mode)
- Verify clear sky view and antenna connections
- Review str2str_file service logs: `sudo journalctl -u str2str_file -n 100`
- Check rover.pos file is being written: `tail -f ~/rtkbase/rover.pos`

### Low Quality Epochs

**Problem:** Many epochs rejected as outliers.

**Solutions:**
- Check for nearby reflective surfaces (buildings, vehicles)
- Verify antenna is stable (no wind-induced motion)
- Increase survey duration to collect more data
- Adjust quality thresholds in config:
  ```python
  controller.parser.min_ratio = 2.5  # Less strict
  controller.parser.max_std_3d = 0.10  # Allow lower quality
  ```

### Survey Fails to Update Configuration

**Problem:** Survey runs but settings.conf not updated.

**Solutions:**
- Check file permissions: `ls -l ~/rtkbase/settings.conf`
- Verify backup directory writable: `ls -ld ~/rtkbase/backups`
- Review logs for specific error: `sudo journalctl -u rtkbase_web -n 50`
- Manually backup and update if needed

### State Recovery Issues

**Problem:** Survey doesn't resume after restart.

**Solutions:**
- Check state file exists: `cat /var/lib/rtkbase/survey_state.json`
- Verify file permissions: `sudo chmod 644 /var/lib/rtkbase/survey_state.json`
- If corrupted, reset manually: `sudo rm /var/lib/rtkbase/survey_state.json`

## Performance

### Expected Accuracy

| Duration | Horizontal | Vertical |
|----------|-----------|----------|
| 1 hour   | 10-20mm   | 20-40mm  |
| 6 hours  | 5-10mm    | 10-20mm  |
| 24 hours | 2-5mm     | 5-10mm   |
| 48 hours | 1-3mm     | 3-7mm    |

*Assumes good satellite geometry, minimal multipath, and stable antenna*

### Resource Usage

- **CPU**: < 5% (background thread)
- **Memory**: ~50MB (numpy/scipy arrays)
- **Disk I/O**: Minimal (hourly config updates)
- **Network**: None (uses local files)

## Advanced Configuration

### Custom Quality Thresholds

```python
# Stricter quality for high-precision applications
controller.parser.min_ratio = 5.0
controller.parser.max_std_3d = 0.02  # 2cm

# More lenient for difficult environments
controller.parser.min_ratio = 2.0
controller.parser.max_std_3d = 0.10  # 10cm
```

### Outlier Detection Sensitivity

```python
# More aggressive outlier removal
controller.estimator.outlier_threshold = 3.0

# Less aggressive (keep more data)
controller.estimator.outlier_threshold = 4.0
```

### Update Interval

```python
# Update every 30 minutes (more frequent)
controller.update_interval_hours = 0.5

# Update every 2 hours (less frequent)
controller.update_interval_hours = 2
```

## Integration with RTKBase

Auto Survey-In integrates seamlessly with RTKBase:

1. **No Service Interruption**: Hourly updates allow base to continue operating
2. **Automatic Recovery**: Restarts don't lose survey progress
3. **Configuration Backups**: All updates create timestamped backups
4. **Compatible Services**: Works with all str2str_* services

## License

Part of GeoMaxima extension for RTKBase.
See parent project LICENSE.

## Credits

- RTKLIB: Tomoji Takasu
- RTKBase: Stefal/RTKBase contributors
- GeoMaxima: peshovp

## References

- [RTKLIB Manual](http://www.rtklib.com/prog/manual_2.4.2.pdf)
- [RTKBase Documentation](https://github.com/Stefal/rtkbase)
- [EGM2008 Geoid Model](https://earth-info.nga.mil/index.php?dir=wgs84&action=wgs84)
