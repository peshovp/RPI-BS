# GeoMaxima

Security-hardened GNSS/RTK base station software for Raspberry Pi, built on [Stefal/rtkbase](https://github.com/Stefal/rtkbase).

## Install

On a clean Raspberry Pi OS Trixie (aarch64):

```bash
curl -fsSL https://raw.githubusercontent.com/peshovp/RPI-BS/main/install.sh | sudo bash
```

This single command:
1. Updates the system and installs prerequisites
2. Applies security hardening (UFW, fail2ban, SSH lockdown)
3. Installs RTKBase with GeoMaxima's custom features: OTA updates, audit logging, Auto Survey-In, and authentication

After installation, access the web interface at `http://<pi-ip-address>`.

## Update

Updates can be applied directly from the web UI (Settings → Check for Updates → Update Now), or manually:

```bash
cd RPI-BS && sudo ./addons/tools/perform_update.sh "$(pwd)" "$(pwd)/.update_status.json"
```
