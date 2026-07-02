# Changelog

All notable changes to GeoMaxima will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [4.1.0] - 2026-01-02

### Added
- **GNSS.NET Integration UI:** Added a dedicated web interface for configuring the connection to a central GNSS.NET Caster.
  - Configure Caster URL, Station ID, and API Key.
  - Monitor connection status and last update time.
  - Test connection button.
  - Enable/Disable toggle.
- **Dashboard Integration:** Added direct link to the Integration configuration page from the dashboard features list.

## [4.0.1] - 2026-01-01

### Fixed
- **OTA Update Path Detection:** Fixed "Git repository not found" error by improving repository detection logic to search in all user home directories and accept passed paths.
- **OTA Script Robustness:** Updated `perform_update.sh` to correctly handle repository paths passed from the controller.

## [4.0.0] - 2026-01-01

### Added
- **Auto Survey Persistence:** Added `fsync()` and stabilization delay to ensure coordinates are saved to disk before service restart.
- **UI Auto-Refresh:** Web interface now automatically reloads settings when `settings.conf` changes.
- **Robust OTA Update:**
  - Added `sudo` support for service restarts in update script.
  - Implemented comprehensive logging to `/tmp/ota_update.log`.
  - Added idempotent API endpoints to prevent HTTP 409 errors.
  - Added stale lock cleanup (auto-unlock after 60 minutes).

### Fixed
- Fixed race condition where services restarted before `settings.conf` was flushed to disk.
- Fixed OTA update hanging indefinitely due to missing permissions.
- Fixed "Conflict" errors when retrying updates.

## [3.2.3] - 2025-12-28

### Changed
- OTA Update page now shows a visible "UI refresh build 3.2.3" pill so operators can confirm the new theme and tucked rollback toggle are deployed.
- Bumped version to 3.2.3 to surface the update for field nodes that still report 3.2.2.

## [3.2.4] - 2025-12-28

### Changed
- OTA Update UI switched to a light, minimal style matching RTKBase: white cards, subtle borders, default Bootstrap button colors, no gradients.
- Removed the release pill from the header to keep the page clean.

## [3.2.5] - 2025-12-28

### Fixed
- OTA Update API now returns `success=true` with `status="in_progress"` when the detached update starts, preventing immediate "Unknown error" popups.
- Status file writing ensures the parent directory exists before saving, improving reliability on fresh deployments.

## [3.2.6] - 2025-12-28

### Fixed
- Geoid upload now reports the precise load error back to the UI and logs it; geoid header parsing is more robust for RTKLIB .ggf files (reads full header line, little-endian float32 grid, better error messages).

## [3.2.7] - 2025-12-28

### Added
- OTA Update page: "GitHub Access Token" section to store a personal access token for private repositories. Token is saved locally and used via `GIT_ASKPASS` securely.

### Changed
- OTA update script now logs actual `git fetch` errors and the auth mode (public/token) and remote URLs to aid diagnosis in the UI.
- Auto Survey interim/final updates also write `ant_lat`, `ant_lon`, and `ant_height` in `[main]` alongside the `position` line, ensuring RTKBase UI reflects live coordinate updates during the survey.

### Fixed
- Safer placement of `position` inside `[main]` when missing; creates the section and fields if needed.

## [2.2.2] - 2025-12-28

### Fixed
- OTA update reliability: update script now accepts explicit repo path, searches deployed path, and avoids "Git repository not found" failures on production nodes.
- Synced OTA controller/template/script to deployed path and ensured executable bit is set to keep background updates working after restart.

## [2.2.1] - 2025-12-28

### Changed
- OTA Update page restyled with a minimal, modern palette and reduced visual weight on secondary elements.
- Rollback section is now collapsed by default behind a “Show recovery options” toggle to avoid accidental use.

## [2.2.0] - 2025-12-24

### 🎉 NEW FEATURE - GNSS Receiver Configuration Manager

#### Added
- **GNSS Receiver Auto-Detection** - Automatic detection of connected receivers
  - Scans serial ports (/dev/ttyACM*, /dev/ttyUSB*, /dev/ttyS*)
  - Tests 8 baudrates (9600 to 921600)
  - Supports ZED-F9P (u-blox), Mosaic-X5 (Septentrio), UM980/UM982 (Unicore)
  - Detects firmware version and receiver type

- **ZED-F9P Configurator** (U-blox)
  - Full UBX protocol implementation
  - Configure RTCM3 messages (1005, 1074, 1077, 1084, 1087, 1094, 1097, 1124, 1127, 1230)
  - Set base mode: auto-survey or fixed position (LLH/ECEF)
  - Set elevation mask, baudrate, and protocols
  - Save configuration to flash memory
  - Receiver reset (hot/warm/cold)

- **Mosaic-X5 Configurator** (Septentrio)
  - ASCII command protocol implementation
  - Configure RTCM3 message output
  - Auto-survey mode with duration and accuracy limits
  - Fixed position mode with LLH coordinates
  - Antenna type configuration
  - Elevation mask setting
  - Save to flash and receiver reset

- **UM980/UM982 Configurator** (Unicore)
  - ASCII protocol implementation
  - Configure RTCM3 messages on multiple ports
  - Base mode: auto-survey with duration
  - Fixed position mode with LLH coordinates
  - GNSS system selection (GPS, GLONASS, Galileo, BeiDou, QZSS)
  - Elevation mask and configuration save

- **Configuration Profile Management**
  - Save receiver configurations as named profiles
  - Load profiles to quickly apply settings
  - Delete unwanted profiles
  - Import profiles from JSON files
  - Export profiles for backup or sharing
  - Profile metadata (receiver type, timestamp, description)

- **Web Interface** at `/geomaxima/gnss-config`
  - Receiver scanning and selection
  - Real-time configuration feedback
  - RTCM message selection with checkboxes
  - Base mode toggle (auto-survey vs fixed)
  - Visual profile management
  - Import/export functionality
  - Progress indicators and status messages

## [Unreleased]

### Added
- **OTA Update Manager** - Web-based over-the-air updates without SSH/terminal access
  - Check for updates from GitHub repository
  - View current version and commit history
  - One-click update with automatic service restart
  - Real-time update progress and detailed logs
  - Automatic git stash for local changes
  - Auto-run install script after pull
  - Access at: `http://station-ip/geomaxima/update`

### Changed
- Reorganized templates into `templates/geomaxima/` subfolder for better structure
- Installer no longer auto-starts file logging service on installation
- File logging only starts when user initiates Auto Survey or manually via RTKBase SERVICES

### Removed
- **Manual logging controls from UI** - RTKBase already has file logging controls in SERVICES page
- API endpoints `/api/survey/logging/start` and `/api/survey/logging/stop` - duplicated RTKBase functionality

### Fixed
- JavaScript duplicate code in auto_survey.html breaking Start Survey button
- Installer automatically starting file logging causing unnecessary disk usage
- Improved hostname patch application with intelligent dual-file checking

## [1.3.1] - 2025-12-22

### 🚨 CRITICAL UPDATE - Prevents Disk Space Exhaustion

#### Added
- **Automatic logging stop after survey completion** - File logging service now stops automatically when survey completes or is manually stopped to prevent disk space issues
- Manual logging controls in UI - Start/stop file logging independently of survey
- API endpoints for logging control: `/api/survey/logging/start` and `/api/survey/logging/stop`
- Warning message in UI about automatic logging management

#### Changed
- Survey finalization now automatically stops file logging service
- Manual survey stop also stops file logging service
- Enhanced logging with clear messages about disk space management

#### Fixed
- **CRITICAL**: Continuous GNSS data accumulation filling device storage (~75MB/hour = 1.8GB/day)
- File logging running indefinitely after survey completion

#### Technical Details
- Modified `survey_controller.py`: Added `_stop_file_logging()` method
- Modified `auto_survey_feature.py`: Added logging control API endpoints
- Modified `auto_survey.html`: Added manual logging control buttons
- Updated documentation with disk management troubleshooting

**Typical Impact:**
- Before v1.3.1: 24h survey + 7 days = ~12GB disk usage ❌
- After v1.3.1: 24h survey = 1.8GB (auto-stopped) ✅

**MANDATORY upgrade for all production deployments!**

## [1.3.0] - 2025-12-22

### 🚀 Major Release - Production Ready Auto Survey-In

#### Critical Bug Fixes
- **Fixed**: Missing rnx2rtkp tool - added automatic compilation from RTKLIB source
- **Fixed**: Missing gfortran dependency causing compilation failures
- **Fixed**: RINEX conversion failing due to incorrect convbin flags (-o, -n)
- **Fixed**: Position parser failing on GPS week/second format output
- **Fixed**: AttributeError when accessing position data (dict vs object compatibility)
- **Fixed**: Position updates not reflected in RTKBase UI without restart
- **Fixed**: Missing ratio and ns fields in SPP .pos file parsing

#### New Features
- **Added**: Automatic RTKLIB rnx2rtkp compilation and installation
- **Added**: Auto-discovery of RTKLIB tools (convbin, rnx2rtkp) via shutil.which()
- **Added**: Dual-format position parser (GPS week/second + date/time)
- **Added**: Automatic config reload after position updates
- **Added**: Hostname display in browser tabs (e.g., "Auto Survey-In - BS-Aheloy")
- **Added**: RTKBase hostname patch system for global hostname display

#### Improvements
- **Improved**: Installer with forced file synchronization (rsync --delete)
- **Improved**: Template verification logging during installation
- **Improved**: Position estimator with safe dict.get() for optional fields
- **Improved**: Error messages and logging throughout the codebase
- **Added**: Python cache clearing before service restarts

#### Validation
- ✅ Tested with 34,123 SPP epochs in production
- ✅ BGR2005 geoid correction verified (~46m separation)
- ✅ Outlier rejection working (921/34,123 rejected)
- ✅ Accuracy: ~8.3m horizontal, ~11.2m vertical (1-hour survey)

### Technical Details
- Modified files:
  - `install_local.sh` - Added install_rnx2rtkp(), improved deployment
  - `features/auto_survey/rinex_converter.py` - Fixed convbin command
  - `features/auto_survey/spp_processor.py` - Dual-format parser
  - `features/auto_survey/position_estimator.py` - Dict compatibility
  - `features/auto_survey/rtkbase_config.py` - Auto-reload
  - `features/auto_survey_feature.py` - Hostname support
  - `templates/auto_survey.html` - JavaScript title update
- New files:
  - `patches/rtkbase_hostname.patch` - Global hostname display

## [1.1.0] - 2025-01-16

### Added
- **Auto Survey-In** - Automatic 24-hour precise GNSS positioning
  - RTKLIB solution parsing with quality filtering (FIX only, Q=1)
  - Statistical position estimation with outlier rejection
  - Modified Z-Score (MAD-based) outlier detection
  - Weighted averaging with inverse variance weighting
  - Geoid height correction from .ggf files (EGM96/EGM2008)
  - Ellipsoidal to orthometric height conversion
  - RTKBase configuration updates with automatic backups
  - State persistence for restart recovery
  - 24-hour survey loop with hourly coordinate updates
  - Real-time web interface with progress monitoring
  - Quality metrics display (ratio, satellites, accuracy)
  - REST API endpoints for control and status
  - Comprehensive documentation and usage guide
- **Dependencies** - Scientific computing libraries
  - numpy ≥1.19.0 for array operations
  - scipy ≥1.5.0 for statistical functions
  - Added `requirements.txt` for dependency management

### Changed
- Updated `VERSION` from 1.0.2 to 1.1.0
- Enhanced dashboard to show Auto Survey-In feature card
- Updated `config.py` with `auto_survey` feature flag

### Technical Details
- 7 new Python modules in `features/auto_survey/`
  - `gnss_parser.py` - RTKLIB solution parsing
  - `position_estimator.py` - Statistical processing
  - `geoid_corrector.py` - Geoid height correction
  - `config_manager.py` - Safe configuration updates
  - `state_manager.py` - State persistence
  - `survey_controller.py` - Main orchestration
- New template `auto_survey.html` - Complete web UI
- New API feature file `auto_survey_feature.py`
- Feature documentation in `features/auto_survey/README.md`
- Implementation notes in `FEATURE_AUTO_SURVEY.md`

## [1.0.2] - 2025-12-18

### Added
- **WireGuard VPN Client** - Full web-based VPN management interface
  - Configure WireGuard through web interface
  - Connect/Disconnect VPN connections
  - Enable/Disable autostart on boot
  - Real-time connection status monitoring
  - Configuration editor with modal dialog
  - Data transfer statistics display
- **Dashboard UI** - RTKBase-compatible design
  - Clean, minimal layout matching RTKBase theme
  - System information panel with version and status
  - Quick Links section for API endpoints
  - Feature cards with enable/disable status
  - Responsive layout for mobile devices
- **Templates System** - Proper Jinja2 templates
  - `dashboard.html` - Main GeoMaxima dashboard
  - `wireguard.html` - WireGuard VPN management UI
  - Templates copied to RTKBase web_app during installation
- **Static Assets** - CSS and JavaScript files
  - `geomaxima.css` - RTKBase-compatible styling
  - `geomaxima.js` - Dashboard functionality
  - `wireguard.js` - WireGuard management logic
  - Assets copied to RTKBase web_app/static during installation
- **Installation Improvements**
  - Automatic template and static files deployment
  - Python cache cleanup before service restart
  - Proper server.py integration at correct location
  - Smart detection of existing installations
- **Documentation**
  - GitHub CLI installation guide for private repos
  - Step-by-step authentication instructions
  - Multiple installation methods documented

### Fixed
- Blueprint registration in multi-worker Gunicorn environment
  - Routes now registered before blueprint registration
  - Prevents "route can no longer be called" errors
  - Proper singleton pattern for controller instance
- Template rendering issues
  - Removed hardcoded feature route references
  - Dynamic feature status display
  - Proper template path configuration in Blueprint
- Installation script robustness
  - Correct indentation in server.py integration
  - Heredoc usage for Python code injection
  - Executable permissions for shell scripts
  - Directory preservation during RTKBase installation

### Changed
- Dashboard design updated to match RTKBase theme
  - Replaced colored cards with `border bg-light` style
  - Simplified navigation and layout
  - Bootstrap 4.6.1 compatible components
- API endpoints now return proper JSON responses
- Feature detection improved with better error handling

### Technical Details
- Blueprint now includes `template_folder` and `static_folder` configuration
- Global `_routes_registered` flag prevents duplicate route registration
- Install script uses `sed` for server.py integration with proper indentation
- Cache cleanup included in service restart procedure

## [1.0.1] - 2025-12-18

### Added
- Initial modular architecture
- Blueprint-based routing system
- Feature system foundation
- Basic dashboard structure
- Installation scripts (online and offline)
- OTA update mechanism
- GitHub integration

### Fixed
- Various installation issues
- Path detection problems
- Service integration bugs

## [1.0.0] - 2025-12-17

### Added
- Initial release
- Core GeoMaxima system
- Basic feature framework
- RTKBase integration
- Web interface foundation

[1.0.2]: https://github.com/peshovp/GeoMaxima-BS/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/peshovp/GeoMaxima-BS/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/peshovp/GeoMaxima-BS/releases/tag/v1.0.0
