# Building GeoMaxima Releases

## 📦 Quick Build

### Linux/Mac:
```bash
./build_release.sh
```

### Windows:
```powershell
.\build_release.ps1
```

**Output:** `Output/GeoMaxima-vX.X.X.zip`

## 🎯 What Gets Included

The build script packages:
- ✅ Core system files (`config.py`, `controller.py`, `__init__.py`)
- ✅ All features (`features/`)
- ✅ Installation scripts (`install.sh`, `install_local.sh`)
- ✅ Documentation (`README.md`, `QUICKSTART_BG.md`, etc.)
- ✅ Dependencies list (`requirements-geomaxima.txt`)
- ✅ Update script (`geomaxima_update.sh`)

## 📂 Archive Structure

```
GeoMaxima-vX.X.X.zip
└── GeoMaxima/          ← Extracts to this folder
    ├── features/
    ├── install_local.sh
    ├── config.py
    └── ...
```

## 🚀 Distribution

1. **Build release**
2. **Transfer ZIP** to RTKBase (USB, SCP, etc.)
3. **Extract and install**:
   ```bash
   unzip GeoMaxima-vX.X.X.zip
   cd GeoMaxima
   sudo ./install_local.sh
   ```

## 📝 Notes

- Output/ folder is **not tracked by git**
- Archives are for distribution only
- Version is read from `VERSION` file
- Each build is independent and complete
