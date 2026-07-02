# GeoMaxima v1.0.2 - Production Ready 🚀

## Overview

GeoMaxima v1.0.2 is a production-ready release with a complete WireGuard VPN Client interface and RTKBase-compatible design. This release includes major UI improvements, full template system, and robust installation procedures.

## ✨ What's New

### 🔐 WireGuard VPN Client
Full web-based VPN management interface:
- **Configuration Editor** - Edit WireGuard config directly in browser
- **Connection Control** - Connect/Disconnect with one click
- **Autostart Management** - Enable/disable VPN on boot
- **Status Monitoring** - Real-time connection status and statistics
- **Installation Support** - Automatic WireGuard installation if not present

### 🎨 Dashboard Redesign
Clean, RTKBase-compatible interface:
- Minimal layout matching RTKBase theme
- System information panel
- Feature cards with status indicators
- Quick access to API endpoints
- Responsive mobile-friendly design

### 📦 Installation System
Improved deployment experience:
- **GitHub CLI Support** - Easy private repo access
- **Offline Installation** - ZIP archive support
- **Smart Detection** - Automatic RTKBase installation if missing
- **Template Deployment** - Automatic copying of UI files
- **Cache Management** - Python cache cleanup before restart

## 🔧 Technical Improvements

- ✅ Fixed Blueprint registration in multi-worker environment
- ✅ Proper template and static file handling
- ✅ Correct server.py integration with heredoc
- ✅ Python cache cleanup before service restart
- ✅ Executable permissions for shell scripts

## 📥 Installation

### Method 1: GitHub CLI (Private Repos)
```bash
gh repo clone peshovp/GeoMaxima-BS GeoMaxima
cd GeoMaxima
sudo ./install_local.sh
```

### Method 2: Offline ZIP
```bash
unzip GeoMaxima-v1.0.2.zip
cd GeoMaxima
sudo ./install_local.sh
```

### Method 3: Git Update (Existing Installation)
```bash
cd ~/GeoMaxima
git pull
sudo ./install_local.sh
```

## 🎯 Features

### Active Features
- ✅ **WireGuard Client** - Full VPN management
- ✅ **Example Feature** - Demo feature template

### Disabled Features
- 🔲 **Custom Analytics** - Ready for activation
- 🔲 **External Integration** - Ready for activation

## 📊 API Endpoints

- `GET /geomaxima/` - Dashboard
- `GET /geomaxima/wireguard` - WireGuard UI
- `GET /geomaxima/api/info` - System information
- `GET /geomaxima/api/status` - System status
- `GET /geomaxima/api/features` - Features list
- `POST /geomaxima/api/wireguard/connect` - Connect VPN
- `POST /geomaxima/api/wireguard/disconnect` - Disconnect VPN
- `POST /geomaxima/api/wireguard/enable` - Enable autostart
- `POST /geomaxima/api/wireguard/disable` - Disable autostart
- `POST /geomaxima/api/wireguard/config` - Save configuration
- `DELETE /geomaxima/api/wireguard/config` - Delete configuration

## 📝 Requirements

- RTKBase 2.7.0+ (automatically installed if missing)
- Debian 12+ / Ubuntu 24.04+ / Raspberry Pi OS
- Python 3.9+
- Root access (sudo)

## 🐛 Bug Fixes

- Fixed Blueprint "route can no longer be called" error
- Fixed template rendering issues
- Fixed installation script indentation errors
- Fixed Python cache causing stale imports
- Fixed executable permissions in ZIP archives

## 📚 Documentation

- [README.md](README.md) - Main documentation
- [CHANGELOG.md](CHANGELOG.md) - Full changelog
- [QUICKSTART_BG.md](QUICKSTART_BG.md) - Quick start guide (Bulgarian)

## 🔗 Links

- **GitHub Repository**: https://github.com/peshovp/GeoMaxima-BS
- **RTKBase**: https://github.com/Stefal/rtkbase

## 🙏 Credits

Built with ❤️ for RTKBase community

---

**Full Changelog**: https://github.com/peshovp/GeoMaxima-BS/compare/v1.0.1...v1.0.2
