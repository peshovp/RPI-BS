# GeoMaxima Extension for RTKBase

[![Version](https://img.shields.io/badge/version-1.9.3-blue.svg)](https://github.com/peshovp/GeoMaxima-BS/releases/latest)
[![RTKBase](https://img.shields.io/badge/RTKBase-2.7.0-green.svg)](https://github.com/Stefal/rtkbase)
[![License](https://img.shields.io/badge/license-MIT-orange.svg)](LICENSE)

## 🎯 Overview

GeoMaxima is a production-ready modular extension system for RTKBase that adds advanced GNSS functionality while maintaining full compatibility with RTKBase's native updates.

**Version 1.9.3** adds fully automated installation and OTA updates for private repositories.

## ✨ Key Features

### 🎯 Auto Survey-In v1.3.1 (Production Ready)
**Automatic 24-hour precise base station positioning with disk management**

- ✅ **Fully Automated** - From raw GNSS logs to accurate coordinates
- ✅ **RINEX Processing** - Automatic conversion from UBX/RTCM to RINEX
- ✅ **SPP Positioning** - Single Point Positioning using RTKLIB rnx2rtkp
- ✅ **BGR2005 Geoid** - Accurate orthometric heights for Bulgaria
- ✅ **Robust Statistics** - Modified Z-Score outlier rejection (MAD-based)
- ✅ **Progressive Updates** - Hourly coordinate refinement over 24 hours
- ✅ **Auto-Discovery** - Finds RTKBase paths and configuration automatically
- ✅ **🚨 Disk Management** - Auto-stops logging after completion (v1.3.1)

**Typical Results:**
- 1-hour survey: ~8m horizontal, ~11m vertical accuracy
- 24-hour survey: ~1-2m horizontal, ~2-3m vertical accuracy (SPP baseline)
- Tested with 34,123 epochs, 921 outliers rejected

### 🔐 WireGuard VPN Client
**Full web-based VPN management**

- Configure WireGuard through web interface
- Edit config files directly in browser
- Start/Stop/Restart VPN connections
- Monitor connection status and statistics
- Enable/disable autostart on boot
- View service logs

### 🏗️ Core System
- **Independent Updates** - Update from your own repository
- **Modular Architecture** - Doesn't interfere with RTKBase core
- **Web Integration** - Seamless RTKBase menu integration
- **RESTful API** - Custom endpoints for external integrations

## 🚀 Quick Start

### 📦 Installation Methods

#### **Method 1: Fully Automated (Recommended - with OTA Updates)**

**One command for complete setup:**

```bash
curl -sSL https://raw.githubusercontent.com/peshovp/GeoMaxima-BS/master/install_with_git.sh | sudo bash
```

**Or manual download:**

```bash
wget https://raw.githubusercontent.com/peshovp/GeoMaxima-BS/master/install_with_git.sh
sudo bash install_with_git.sh
```

**What it does:**
1. ✅ Checks for RTKBase installation
2. ✅ Prompts for GitHub Personal Access Token (one time)
3. ✅ Configures `.netrc` for private repo access
4. ✅ Clones GeoMaxima repository
5. ✅ Installs all dependencies and features
6. ✅ Configures passwordless sudo for OTA updates
7. ✅ **Enables web-based OTA updates!**

**GitHub Token Setup:**
1. Go to: https://github.com/settings/tokens
2. Generate new token (classic)
3. Select scope: ✓ `repo` (full control of private repositories)
4. Copy token and paste when prompted

---

#### **Method 2: ZIP Installation (Offline - no OTA updates)**

For air-gapped or offline installations:

```bash
# Download ZIP (on computer with internet)
wget https://github.com/peshovp/GeoMaxima-BS/archive/refs/heads/master.zip

# Transfer to Raspberry Pi (USB stick, etc.)

# Install
unzip master.zip
cd GeoMaxima-BS-master
sudo bash install_from_zip.sh
```

**Note:** This method works offline but **does not enable OTA updates**.

---

#### **Method 3: Manual Git Installation (Advanced)**

If you prefer manual control:

**1. Clone or download repository:**
```bash
cd ~
git clone https://github.com/peshovp/GeoMaxima-BS.git GeoMaxima
cd GeoMaxima
```

**2. Install:**
```bash
sudo ./install_local.sh
```

**3. Access:**
Open RTKBase web interface and click **GEOMAXIMA** tab.

### What Gets Installed

- ✅ GeoMaxima core system (`~/rtkbase/geomaxima/`)
- ✅ Auto Survey-In feature with RINEX processing
- ✅ WireGuard VPN client management
- ✅ RTKLIB tools (convbin, rnx2rtkp) - auto-compiled if missing
- ✅ Dependencies (gfortran, numpy, scipy)
- ✅ Web templates and static files
- ✅ RTKBase integration patches

## 📋 Requirements

### System
- RTKBase 2.7.0+ installed and running
- Raspberry Pi 3/4/5 or compatible SBC
- Debian 11+ / Ubuntu 20.04+
- Root access (sudo)

### Dependencies (Auto-Installed)
- Python 3.7+
- numpy ≥1.19.0
- scipy ≥1.5.0
- gfortran (for RTKLIB compilation)
- libgfortran5 (runtime library)

## 🔄 Upgrading

### Via Web UI (OTA Update)

**If installed with Method 1 (git):**

1. Go to: `http://<your-ip>/geomaxima/update`
2. Click **Check for Updates**
3. If new version available → Click **Install Update**
4. Service restarts automatically ✅

**No SSH required!**

---

### Via Command Line

**If you have git repository:**

```bash
cd ~/GeoMaxima
git pull origin master
sudo bash install_local.sh
sudo systemctl restart rtkbase_web
cd ~/GeoMaxima
git pull origin master
sudo ./install_local.sh
```

The installer automatically:
- Backs up existing configuration
- Updates all files
- Clears Python cache
- Restarts services
- Applies RTKBase patches

## 📚 Documentation
   - Select: **HTTPS**
   - Authenticate with: **Login with a web browser** (or paste token)
   - Copy the one-time code and open the URL in browser
   - Enter the code and authorize

3. **Clone and install**:
   ```bash
   cd ~
   gh repo clone peshovp/GeoMaxima-BS GeoMaxima
   cd GeoMaxima
   sudo ./install_local.sh
   ```

**What it does:**
- ✅ Authenticates with private GitHub repository
- ✅ Clones repository securely
- ✅ Installs GeoMaxima with all features
- ✅ Automatic integration with RTKBase

**Requirements:**
- RTKBase already installed
- Root access (sudo)
- Internet connection
- GitHub account with repo access

---

### Method 3: Online Installation (For Public Repos)

The installer automatically detects if RTKBase is already installed and acts accordingly:

```bash
wget -O - https://raw.githubusercontent.com/peshovp/GeoMaxima-BS/master/install.sh | sudo bash
```

**What it does:**
- ✅ **RTKBase found?** → Installs GeoMaxima only
- ✅ **RTKBase missing?** → Installs RTKBase + GeoMaxima
- ✅ Automatic integration and service restart
- ✅ Backup of existing installation

**Requirements:**
- Debian 12+ / Ubuntu 24.04+
- Root access (sudo)
- Internet connection
- Repository must be public

## 🔄 Update System

GeoMaxima has its own update mechanism that:
- Pulls updates from your custom repository
- Preserves RTKBase's ability to update independently
- Keeps custom configurations separate

### Manual Update
```bash
cd /path/to/rtkbase
sudo ./geomaxima/geomaxima_update.sh
```

### Auto Update (Timer)
```bash
sudo systemctl enable geomaxima_update.timer
sudo systemctl start geomaxima_update.timer
```

## 📁 Structure

```
geomaxima/
├── README.md                    # This file
├── VERSION                      # Current version
## 📁 Project Structure

```
GeoMaxima/
├── README.md                   # This file
├── CHANGELOG.md                # Version history
├── VERSION                     # Current version
├── install_local.sh            # Main installer
├── __init__.py                 # Package init
├── config.py                   # Configuration
├── controller.py               # Main controller
│
├── docs/                       # 📚 Documentation
│   ├── README.md
│   ├── QUICKSTART_BG.md        # Quick start (Bulgarian)
│   ├── FEATURE_AUTO_SURVEY.md  # Auto Survey docs
│   ├── TESTING_AUTO_SURVEY.md  # Testing guide
│   ├── BUILD.md                # Build instructions
│   ├── DEPLOY.md               # Deployment guide
│   └── SETUP_GITHUB.md         # GitHub setup
│
├── scripts/                    # 🔧 Installation & Build
│   ├── README.md
│   ├── build_release.sh        # Linux/Mac build
│   ├── build_release.ps1       # Windows build
│   ├── geomaxima_update.sh     # Update script
│   └── install*.sh             # Legacy installers
│
├── releases/                   # 📦 Release Notes
│   ├── README.md
│   ├── release_notes_v1.3.1.md # Latest
│   ├── RELEASE_NOTES_v1.3.0.md
│   └── RELEASE_NOTES_v1.*.md
│
├── features/                   # 🎯 Feature Modules
│   ├── __init__.py
│   ├── auto_survey/            # Auto Survey-In
│   │   ├── __init__.py
│   │   ├── survey_controller.py
│   │   ├── rinex_converter.py
│   │   ├── spp_processor.py
│   │   └── ...
│   ├── auto_survey_feature.py
│   └── wireguard_feature.py
│
├── templates/                  # 🎨 Web Templates
│   └── geomaxima/
│       ├── auto_survey.html
│       └── wireguard_config.html
│
├── static/                     # 📱 Frontend Assets
│   └── geomaxima/
│       ├── css/
│       └── js/
│
└── patches/                    # 🔧 RTKBase Patches
    ├── rtkbase_hostname.patch
    └── README.md
```

## 📚 Documentation

- **[Quick Start (BG)](docs/QUICKSTART_BG.md)** - Бърз старт на български
- **[Auto Survey Guide](docs/FEATURE_AUTO_SURVEY.md)** - Complete Auto Survey-In documentation
- **[Testing Guide](docs/TESTING_AUTO_SURVEY.md)** - How to test Auto Survey-In
- **[Build Guide](docs/BUILD.md)** - Building release archives
- **[Deployment Guide](docs/DEPLOY.md)** - Production deployment
- **[Changelog](CHANGELOG.md)** - Complete version history
- **[Releases](releases/)** - Release notes archive

## 🔗 Links

- **GitHub Repository:** https://github.com/peshovp/GeoMaxima-BS
- **Latest Release:** https://github.com/peshovp/GeoMaxima-BS/releases/latest
- **RTKBase Project:** https://github.com/Stefal/rtkbase
- **RTKLIB:** https://github.com/rtklibexplorer/RTKLIB

## 📄 License

Same as RTKBase (GNU AGPL v3)
