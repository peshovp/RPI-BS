# 🎯 GeoMaxima Quick Reference

## 📦 Building Releases

### Create ZIP Archive

**Windows:**
```powershell
.\build_release.ps1
```

**Linux/Mac:**
```bash
./build_release.sh
```

**Output:** `Output/GeoMaxima-v1.0.0.zip`

---

## 🚀 Installation Methods

### Method 1: Local Installation (Private Repo - Recommended)

```bash
# 1. Extract archive
unzip GeoMaxima-v1.0.0.zip

# 2. Install
cd GeoMaxima
sudo ./install_local.sh
```

**Use when:**
- ✅ Repository is private
- ✅ No internet on target machine
- ✅ Offline installation needed

---

### Method 2: Online Installation (Public Repo)

```bash
# One-line install (auto-detects RTKBase)
wget -O - https://raw.githubusercontent.com/peshovp/GeoMaxima-BS/master/install.sh | sudo bash
```

**Use when:**
- ✅ Repository is public
- ✅ Internet available
- ✅ Quick setup needed

---

## 🔄 Updating GeoMaxima

### Manual Update

```bash
cd /home/user/rtkbase/geomaxima
sudo ./geomaxima_update.sh
```

### From New ZIP

```bash
# Extract new version
unzip GeoMaxima-v1.1.0.zip

# Install (automatically backs up old version)
cd GeoMaxima
sudo ./install_local.sh
```

---

## ✅ Verification

### Check Installation

```bash
# API check
curl http://localhost/geomaxima/api/info

# Service status
sudo systemctl status rtkbase_web

# View logs
sudo journalctl -u rtkbase_web -f
```

### Access Web Interface

- **Dashboard:** `http://YOUR_IP/geomaxima`
- **WireGuard:** `http://YOUR_IP/geomaxima/wireguard`

---

## 🛠️ Quick Troubleshooting

### GeoMaxima Not Loading

```bash
# Restart service
sudo systemctl restart rtkbase_web

# Check logs
sudo journalctl -u rtkbase_web | grep -i geomaxima
```

### Permission Issues

```bash
# Fix permissions
cd /home/user/rtkbase
sudo chown -R $(stat -c '%U' .) geomaxima
sudo chmod -R 755 geomaxima
```

### Python Import Errors

```bash
# Reinstall dependencies
cd /home/user/rtkbase/geomaxima
sudo pip3 install -r requirements-geomaxima.txt
```

---

## 📚 Documentation

- **README.md** - Main documentation
- **QUICKSTART_BG.md** - Bulgarian quick start
- **BUILD.md** - Build instructions
- **DEPLOYMENT.md** - Production deployment
- **SETUP_GITHUB.md** - GitHub authentication
- **features/WIREGUARD.md** - WireGuard feature docs

---

## 🎛️ Development Workflow

### 1. Make Changes
Edit files in `geomaxima/`

### 2. Test Locally
```bash
# Restart to test
sudo systemctl restart rtkbase_web
```

### 3. Commit Changes
```bash
git add .
git commit -m "Description"
git push
```

### 4. Build Release
```powershell
.\build_release.ps1
```

### 5. Distribute
Transfer `Output/GeoMaxima-vX.X.X.zip` to target systems

---

## 📞 Support

**Repository:** https://github.com/peshovp/GeoMaxima-BS

**Version:** Check `VERSION` file

**RTKBase:** https://github.com/Stefal/rtkbase
