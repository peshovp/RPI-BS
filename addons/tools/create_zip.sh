#!/usr/bin/env bash
# Create offline ZIP package of GeoMaxima
# Excludes VCS and build artefacts; includes installer

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
VERSION_FILE="${ROOT_DIR}/VERSION"
VERSION="$(cat "${VERSION_FILE}")"
OUT_NAME="GeoMaxima-v${VERSION}.zip"
OUT_PATH="${ROOT_DIR}/${OUT_NAME}"

echo "Packaging ${OUT_NAME}..."

# Build temp staging to control content
STAGE_DIR="${ROOT_DIR}/.release_stage"
rm -rf "${STAGE_DIR}" 2>/dev/null || true
mkdir -p "${STAGE_DIR}"

# Copy repo content
rsync -av --delete \
  --exclude=".git" \
  --exclude=".github" \
  --exclude="__pycache__" \
  --exclude="*.pyc" \
  --exclude="geomaxima_survey" \
  --exclude="backups" \
  --exclude=".release_stage" \
  "${ROOT_DIR}/" "${STAGE_DIR}/" >/dev/null

# Ensure installer is executable
find "${STAGE_DIR}" -type f -name "install_local.sh" -exec chmod +x {} \; || true

# Zip
cd "${STAGE_DIR}/.."
zip -r "${OUT_NAME}" ".release_stage" >/dev/null
mv ".release_stage.zip" "${OUT_PATH}" 2>/dev/null || true
rm -rf "${STAGE_DIR}"

echo "Created: ${OUT_PATH}"
