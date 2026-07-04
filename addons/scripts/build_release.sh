#!/bin/bash

################################################################################
# GeoMaxima Release Builder
# 
# Creates ZIP archive for offline installation
# Output: Output/GeoMaxima-vX.X.X.zip
################################################################################

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[✓]${NC} $1"; }
log_step() { echo -e "${BLUE}[→]${NC} $1"; }

# Read version
if [ -f "VERSION" ]; then
    VERSION=$(cat VERSION)
else
    VERSION="1.0.0"
fi

OUTPUT_DIR="Output"
ARCHIVE_NAME="GeoMaxima-v${VERSION}.zip"
OUTPUT_PATH="${OUTPUT_DIR}/${ARCHIVE_NAME}"

log_step "Building GeoMaxima release v${VERSION}..."

# Create Output directory
mkdir -p "${OUTPUT_DIR}"

# Create temporary directory with GeoMaxima structure
TEMP_DIR=$(mktemp -d)
GEOMAXIMA_DIR="${TEMP_DIR}/GeoMaxima"
mkdir -p "${GEOMAXIMA_DIR}"

log_step "Copying files..."

# Copy all necessary files
cp -r features "${GEOMAXIMA_DIR}/"
cp VERSION "${GEOMAXIMA_DIR}/"
cp config.py "${GEOMAXIMA_DIR}/"
cp controller.py "${GEOMAXIMA_DIR}/"
cp __init__.py "${GEOMAXIMA_DIR}/"
cp geomaxima_update.sh "${GEOMAXIMA_DIR}/"
cp requirements-geomaxima.txt "${GEOMAXIMA_DIR}/"
cp .gitignore "${GEOMAXIMA_DIR}/"
cp README.md "${GEOMAXIMA_DIR}/"
cp QUICKSTART_BG.md "${GEOMAXIMA_DIR}/"
cp SETUP_GITHUB.md "${GEOMAXIMA_DIR}/"
cp DEPLOYMENT.md "${GEOMAXIMA_DIR}/"
cp install.sh "${GEOMAXIMA_DIR}/"
cp install_local.sh "${GEOMAXIMA_DIR}/"

log_step "Creating archive..."

# Create ZIP archive (archive contains GeoMaxima/ folder)
cd "${TEMP_DIR}"
zip -r -q "${ARCHIVE_NAME}" GeoMaxima/

# Move to Output directory
mv "${ARCHIVE_NAME}" "$(dirname "${TEMP_DIR}")/${OUTPUT_PATH}"

# Cleanup
rm -rf "${TEMP_DIR}"

log_info "✅ Release created: ${OUTPUT_PATH}"
log_info "Size: $(du -h "${OUTPUT_PATH}" | cut -f1)"
echo ""
log_info "📦 Ready for distribution!"
log_info "   Extract and run: sudo ./GeoMaxima/install_local.sh"
