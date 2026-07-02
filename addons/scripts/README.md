# Installation & Build Scripts

This directory contains all installation and build scripts.

## Installation Scripts

### Main Installer
- **install_local.sh** - Main production installer (located in root for easy access)

### Legacy Installers (kept for reference)
- **install.sh** - Original installer
- **install_geomaxima.sh** - GeoMaxima specific installer
- **install_geomaxima_quick.sh** - Quick install variant

## Build Scripts

- **build_release.sh** - Linux/Mac build script
- **build_release.ps1** - Windows PowerShell build script

## Update Scripts

- **geomaxima_update.sh** - Update existing GeoMaxima installation

## Usage

### Fresh Installation
```bash
cd ~/GeoMaxima
sudo ./install_local.sh
```

### Build Release Archive
```bash
# Linux/Mac
./scripts/build_release.sh

# Windows
.\scripts\build_release.ps1
```

### Update Existing Installation
```bash
sudo ./scripts/geomaxima_update.sh
```

## Notes

- Main installer (`install_local.sh`) is kept in root directory for convenience
- All other scripts moved to `scripts/` for organization
- Legacy scripts preserved for historical reference
