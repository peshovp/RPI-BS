#!/bin/bash

###############################################################################
# GeoMaxima OTA Update Script
# 
# This script updates GeoMaxima extension independently from RTKBase
# Updates are pulled from your custom repository
###############################################################################

set -e  # Exit on error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEOMAXIMA_DIR="${SCRIPT_DIR}"
RTKBASE_DIR="$(dirname "${GEOMAXIMA_DIR}")"
BACKUP_DIR="/var/tmp/geomaxima_backup_$(date +%Y%m%d_%H%M%S)"
TEMP_DIR="/var/tmp/geomaxima_update"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Load configuration
if [ -f "${GEOMAXIMA_DIR}/config.py" ]; then
    REPO_URL=$(grep "GEOMAXIMA_REPO" "${GEOMAXIMA_DIR}/config.py" | sed 's/.*"\(.*\)".*/\1/')
    BRANCH=$(grep "GEOMAXIMA_BRANCH" "${GEOMAXIMA_DIR}/config.py" | sed 's/.*"\(.*\)".*/\1/')
else
    echo -e "${RED}Error: config.py not found${NC}"
    exit 1
fi

# Default values if not set
REPO_URL=${REPO_URL:-"https://github.com/yourusername/geomaxima-extensions.git"}
BRANCH=${BRANCH:-"main"}

echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}GeoMaxima Update Script${NC}"
echo -e "${GREEN}================================${NC}"
echo ""
echo "Repository: ${REPO_URL}"
echo "Branch: ${BRANCH}"
echo ""

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Please run this script with sudo${NC}"
    exit 1
fi

# Function to rollback on error
rollback() {
    echo -e "${YELLOW}Rolling back to previous version...${NC}"
    if [ -d "${BACKUP_DIR}" ]; then
        rm -rf "${GEOMAXIMA_DIR}"
        cp -r "${BACKUP_DIR}" "${GEOMAXIMA_DIR}"
        echo -e "${GREEN}Rollback successful${NC}"
    else
        echo -e "${RED}Backup not found, cannot rollback${NC}"
    fi
    exit 1
}

# Trap errors and rollback
trap rollback ERR

# Create backup
echo -e "${YELLOW}Creating backup...${NC}"
mkdir -p "${BACKUP_DIR}"
cp -r "${GEOMAXIMA_DIR}"/* "${BACKUP_DIR}/"
echo -e "${GREEN}Backup created at ${BACKUP_DIR}${NC}"

# Clean temp directory
echo -e "${YELLOW}Cleaning temporary directory...${NC}"
rm -rf "${TEMP_DIR}"
mkdir -p "${TEMP_DIR}"

# Check if we're using git repo or release
if [ -d "${GEOMAXIMA_DIR}/.git" ]; then
    echo -e "${YELLOW}Updating from git repository...${NC}"
    
    # Store current version
    CURRENT_VERSION=$(cat "${GEOMAXIMA_DIR}/VERSION" 2>/dev/null || echo "unknown")
    
    # Pull latest changes
    cd "${GEOMAXIMA_DIR}"
    git fetch origin
    git reset --hard origin/${BRANCH}
    
    NEW_VERSION=$(cat "${GEOMAXIMA_DIR}/VERSION" 2>/dev/null || echo "unknown")
    
    echo -e "${GREEN}Updated from ${CURRENT_VERSION} to ${NEW_VERSION}${NC}"
else
    echo -e "${YELLOW}GeoMaxima is not a git repository.${NC}"
    echo -e "${YELLOW}To enable git updates, clone your repository:${NC}"
    echo -e "  cd ${RTKBASE_DIR}"
    echo -e "  rm -rf geomaxima"
    echo -e "  git clone ${REPO_URL} geomaxima"
    exit 1
fi

# Install Python dependencies if requirements file exists
if [ -f "${GEOMAXIMA_DIR}/requirements-geomaxima.txt" ]; then
    echo -e "${YELLOW}Installing Python dependencies...${NC}"
    python3 -m pip install -r "${GEOMAXIMA_DIR}/requirements-geomaxima.txt" --extra-index-url https://www.piwheels.org/simple
fi

# Restart web service to apply changes
echo -e "${YELLOW}Restarting RTKBase web service...${NC}"
systemctl restart rtkbase_web.service

# Wait a bit for service to start
sleep 3

# Check if service is running
if systemctl is-active --quiet rtkbase_web.service; then
    echo -e "${GREEN}Service restarted successfully${NC}"
    
    # Clean old backups (keep last 3)
    echo -e "${YELLOW}Cleaning old backups...${NC}"
    cd /var/tmp
    ls -dt geomaxima_backup_* 2>/dev/null | tail -n +4 | xargs -r rm -rf
    
    echo ""
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}Update completed successfully!${NC}"
    echo -e "${GREEN}================================${NC}"
    echo ""
    echo "GeoMaxima version: ${NEW_VERSION}"
    echo "Backup location: ${BACKUP_DIR}"
else
    echo -e "${RED}Service failed to start${NC}"
    rollback
fi

# Clean temp directory
rm -rf "${TEMP_DIR}"

exit 0
