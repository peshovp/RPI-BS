# GeoMaxima Release Builder for Windows
# Creates ZIP archive for offline installation

$ErrorActionPreference = "Stop"

# Read version
$VERSION = Get-Content "VERSION" -ErrorAction SilentlyContinue
if (-not $VERSION) {
    $VERSION = "1.0.0"
}

$OUTPUT_DIR = "Output"
$ARCHIVE_NAME = "GeoMaxima-v$VERSION.zip"
$OUTPUT_PATH = Join-Path $OUTPUT_DIR $ARCHIVE_NAME

Write-Host "[→] Building GeoMaxima release v$VERSION..." -ForegroundColor Blue

# Create Output directory
New-Item -ItemType Directory -Force -Path $OUTPUT_DIR | Out-Null

# Create temporary directory
$TEMP_DIR = Join-Path $env:TEMP "GeoMaxima-Build-$(Get-Random)"
$GEOMAXIMA_DIR = Join-Path $TEMP_DIR "GeoMaxima"
New-Item -ItemType Directory -Force -Path $GEOMAXIMA_DIR | Out-Null

Write-Host "[→] Copying files..." -ForegroundColor Blue

# Copy all necessary files and folders
$itemsToCopy = @(
    "features",
    "VERSION",
    "config.py",
    "controller.py",
    "__init__.py",
    "geomaxima_update.sh",
    "requirements-geomaxima.txt",
    ".gitignore",
    "README.md",
    "QUICKSTART_BG.md",
    "SETUP_GITHUB.md",
    "DEPLOYMENT.md",
    "BUILD.md",
    "CHEATSHEET.md",
    "install.sh",
    "install_local.sh"
)

foreach ($item in $itemsToCopy) {
    if (Test-Path $item) {
        Copy-Item -Path $item -Destination $GEOMAXIMA_DIR -Recurse -Force
    }
}

Write-Host "[→] Creating archive..." -ForegroundColor Blue

# Create ZIP archive
Compress-Archive -Path $GEOMAXIMA_DIR -DestinationPath $OUTPUT_PATH -Force

# Cleanup
Remove-Item -Path $TEMP_DIR -Recurse -Force

$size = (Get-Item $OUTPUT_PATH).Length / 1KB
Write-Host "[✓] Release created: $OUTPUT_PATH" -ForegroundColor Green
Write-Host "[✓] Size: $([math]::Round($size, 2)) KB" -ForegroundColor Green
Write-Host ""
Write-Host "[✓] 📦 Ready for distribution!" -ForegroundColor Green
Write-Host "   Transfer to Linux and extract with: unzip GeoMaxima-v$VERSION.zip" -ForegroundColor Green
Write-Host "   Make scripts executable: chmod +x GeoMaxima/*.sh" -ForegroundColor Yellow
Write-Host "   Then run: sudo ./GeoMaxima/install_local.sh" -ForegroundColor Green
