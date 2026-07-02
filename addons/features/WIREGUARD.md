# WireGuard Client Feature

## 📡 Overview

Full-featured WireGuard VPN Client management through web interface. Configure, edit, start/stop and monitor WireGuard VPN connections without touching the command line.

## ✨ Features

### Configuration Management
- ✅ **Web-based Config Editor** - Edit WireGuard config directly in browser
- ✅ **Syntax Validation** - Validates config before saving
- ✅ **Auto-backup** - Creates backup before overwriting config
- ✅ **Template Support** - Pre-filled configuration template

### Connection Control
- ✅ **Start/Stop/Restart** - Full control over VPN connection
- ✅ **Autostart on Boot** - Enable/disable automatic connection
- ✅ **Real-time Status** - Live connection status updates
- ✅ **Connection Stats** - Transfer statistics (RX/TX)

### Monitoring
- ✅ **Live Status Dashboard** - See connection state instantly
- ✅ **Endpoint Information** - Shows connected server details
- ✅ **Service Logs** - View systemd journal logs
- ✅ **Auto-refresh** - Status updates every 5 seconds

### Installation
- ✅ **One-click Install** - Install WireGuard packages from UI
- ✅ **System Integration** - Uses systemd wg-quick service

## 🚀 Installation

### Prerequisites

WireGuard will be installed automatically through the UI, but you can also install manually:

```bash
sudo apt-get update
sudo apt-get install -y wireguard wireguard-tools
```

### Enable Feature

Feature is enabled by default in `geomaxima/config.py`:

```python
FEATURES = {
    "wireguard_client": True,
}
```

## 📖 Usage

### Access the UI

Navigate to: `http://your-rtkbase-ip/geomaxima/wireguard`

### First Time Setup

1. **Install WireGuard** (if not installed)
   - Click "Install WireGuard" button
   - Wait for installation to complete

2. **Create Configuration**
   - Paste your WireGuard config into the editor
   - Click "Save Configuration"
   
3. **Start VPN**
   - Click "Start VPN" button
   - Monitor connection status

4. **Enable Autostart** (optional)
   - Check "Enable on Boot" checkbox
   - VPN will start automatically on system boot

### Configuration Format

Standard WireGuard configuration format:

```ini
[Interface]
PrivateKey = YOUR_PRIVATE_KEY_HERE
Address = 10.0.0.2/24
DNS = 1.1.1.1

[Peer]
PublicKey = SERVER_PUBLIC_KEY_HERE
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

### Generate Keys

If you need to generate new keys:

```bash
# Generate private key
wg genkey

# Generate public key from private key
echo "PRIVATE_KEY" | wg pubkey
```

## 🔧 API Endpoints

### Get Status
```
GET /geomaxima/api/wireguard/status
```

Returns connection status, interface info, transfer stats.

### Get Configuration
```
GET /geomaxima/api/wireguard/config
```

Returns current WireGuard configuration file.

### Save Configuration
```
POST /geomaxima/api/wireguard/config
Content-Type: application/json

{
  "config": "WireGuard config content here"
}
```

### Control Service
```
POST /geomaxima/api/wireguard/control/<action>
```

Actions: `start`, `stop`, `restart`, `enable`, `disable`

### Get Logs
```
GET /geomaxima/api/wireguard/logs
```

Returns last 50 lines of WireGuard service logs.

### Install WireGuard
```
POST /geomaxima/api/wireguard/install
```

Installs WireGuard packages.

## 🛠️ Configuration Files

### Config Location
```
/etc/wireguard/wg0.conf
```

### Systemd Service
```
wg-quick@wg0.service
```

### Backup Location
```
/etc/wireguard/wg0.conf.backup
```

## 🔐 Security

- Configuration files have **0600** permissions
- Only root can read/write configs
- Web interface requires RTKBase authentication
- Backups created before overwriting
- No plain-text passwords in configs

## 🐛 Troubleshooting

### VPN Not Connecting

1. **Check Configuration**
   - Click "Validate" button
   - Ensure all required fields are present

2. **Check Logs**
   - View logs in the UI
   - Look for error messages

3. **Manual Check**
   ```bash
   sudo systemctl status wg-quick@wg0
   sudo wg show
   ```

### Permission Errors

If you see permission denied errors:

```bash
# Fix config permissions
sudo chmod 600 /etc/wireguard/wg0.conf
sudo chown root:root /etc/wireguard/wg0.conf

# Restart service
sudo systemctl restart wg-quick@wg0
```

### Can't Save Configuration

Web server must run with sudo privileges to write to `/etc/wireguard/`:

```bash
# Check web service user
systemctl cat rtkbase_web.service | grep User

# Service should run as root or with sudo capabilities
```

## 📊 Status Indicators

- **🟢 Connected** - VPN is active and connected to peer
- **🟡 Active (Not Connected)** - Service running but no peer connection
- **🔴 Disconnected** - Service stopped
- **⚪ Not Configured** - No configuration file exists

## 🔄 Auto-refresh

Status dashboard auto-refreshes every 5 seconds to show:
- Connection state
- Endpoint information
- Transfer statistics
- Service status

## 🎯 Use Cases

### Remote Access VPN
Connect RTKBase station to remote network for management.

### Site-to-Site VPN
Link multiple RTKBase stations through VPN tunnel.

### Secure Data Transfer
Encrypt GNSS data streaming through VPN.

### Remote NTRIP Caster
Access NTRIP caster through encrypted tunnel.

## 📝 Example Configs

### Basic Client Config
```ini
[Interface]
PrivateKey = cGFzc3dvcmQ=
Address = 10.0.0.2/24

[Peer]
PublicKey = c2VydmVy
Endpoint = vpn.example.com:51820
AllowedIPs = 10.0.0.0/24
```

### Full Tunnel (Route All Traffic)
```ini
[Interface]
PrivateKey = cGFzc3dvcmQ=
Address = 10.0.0.2/24
DNS = 1.1.1.1

[Peer]
PublicKey = c2VydmVy
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

### Split Tunnel (Specific Routes Only)
```ini
[Interface]
PrivateKey = cGFzc3dvcmQ=
Address = 10.0.0.2/24

[Peer]
PublicKey = c2VydmVy
Endpoint = vpn.example.com:51820
AllowedIPs = 10.0.0.0/24, 192.168.1.0/24
```

## 🔗 Resources

- [WireGuard Official Site](https://www.wireguard.com/)
- [WireGuard Quick Start](https://www.wireguard.com/quickstart/)
- [Systemd Integration](https://wiki.archlinux.org/title/WireGuard#systemd-networkd)

## 📞 Support

For issues with WireGuard feature:
1. Check service logs in UI
2. Validate configuration
3. Check GitHub issues

---

**Feature Status:** ✅ Production Ready

**Last Updated:** December 2025
