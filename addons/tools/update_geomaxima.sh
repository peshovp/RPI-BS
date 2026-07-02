#!/bin/bash
###
### GeoMaxima Update Script
### Updates GeoMaxima features from GitHub repository
###

set -e

GEOMAXIMA_REPO="https://github.com/peshovp/GeoMaxima-BS.git"
RTKBASE_DIR="/home/peshovp/rtkbase"
GEOMAXIMA_TMP="/tmp/geomaxima_update"
STANDARD_USER="${1:-peshovp}"

echo "========================================="
echo "GeoMaxima Update Script"
echo "========================================="

# Check if running as root or with sudo
if [ "$EUID" -eq 0 ]; then 
    echo "Please run without sudo (script will use sudo internally)"
    exit 1
fi

echo "→ Cleaning temporary directory..."
rm -rf "$GEOMAXIMA_TMP"
mkdir -p "$GEOMAXIMA_TMP"

echo "→ Cloning GeoMaxima repository..."
cd "$GEOMAXIMA_TMP"
git clone --depth 1 "$GEOMAXIMA_REPO" .

if [ ! -d "features" ] || [ ! -d "templates" ]; then
    echo "ERROR: Invalid repository structure"
    exit 1
fi

echo "→ Backing up current GeoMaxima installation..."
if [ -d "$RTKBASE_DIR/web_app/geomaxima" ]; then
    sudo cp -r "$RTKBASE_DIR/web_app/geomaxima" "$RTKBASE_DIR/web_app/geomaxima.backup.$(date +%Y%m%d_%H%M%S)"
fi

echo "→ Deploying features..."
sudo mkdir -p "$RTKBASE_DIR/web_app/geomaxima"
sudo rsync -av --delete features/ "$RTKBASE_DIR/web_app/geomaxima/features/"

echo "→ Deploying templates..."
sudo rsync -av --delete templates/ "$RTKBASE_DIR/web_app/templates/"

echo "→ Deploying tools..."
if [ -d "tools" ]; then
    sudo rsync -av tools/ "$RTKBASE_DIR/tools/"
fi

echo "→ Setting permissions..."
sudo chown -R "${STANDARD_USER}:${STANDARD_USER}" "$RTKBASE_DIR/web_app/geomaxima"
sudo chown -R "${STANDARD_USER}:${STANDARD_USER}" "$RTKBASE_DIR/web_app/templates/geomaxima"

echo "→ Installing polkit rules..."
if [ -f "tools/polkit/10-rtkbase-gnss-config.rules" ]; then
    sudo cp tools/polkit/10-rtkbase-gnss-config.rules /etc/polkit-1/rules.d/
    sudo systemctl restart polkit
    echo "  ✓ Polkit rules installed"
fi

echo "→ Updating GeoMaxima repository in rtkbase directory..."
if [ -d "$RTKBASE_DIR/geomaxima" ]; then
    cd "$RTKBASE_DIR/geomaxima"
    sudo -u "${STANDARD_USER}" git pull
else
    sudo -u "${STANDARD_USER}" git clone "$GEOMAXIMA_REPO" "$RTKBASE_DIR/geomaxima"
fi

echo "→ Restarting RTKBase web service..."
sudo systemctl restart rtkbase_web.service

echo "→ Cleaning up..."
rm -rf "$GEOMAXIMA_TMP"

echo ""
echo "========================================="
echo "✓ GeoMaxima updated successfully!"
echo "========================================="
echo ""
echo "Changes deployed:"
echo "  - Features: $RTKBASE_DIR/web_app/geomaxima/features/"
echo "  - Templates: $RTKBASE_DIR/web_app/templates/geomaxima/"
echo "  - Source: $RTKBASE_DIR/geomaxima/"
echo ""
echo "Web service restarted. Refresh your browser."
