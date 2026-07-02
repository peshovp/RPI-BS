# GeoMaxima Quick Deploy Script for Windows
# Usage: .\deploy.ps1

param(
    [string]$Host = "192.168.1.14",
    [string]$User = "peshovp"
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  GeoMaxima Quick Deploy" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

# Check if we're in the right directory
if (!(Test-Path "features") -or !(Test-Path "templates")) {
    Write-Host "ERROR: Run this from geomaxima directory!" -ForegroundColor Red
    exit 1
}

Write-Host "[1/6] Committing changes..." -ForegroundColor Yellow
git add -A
$status = git status --porcelain
if ($status) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    git commit -m "Quick deploy: $timestamp"
    Write-Host "  ✓ Changes committed" -ForegroundColor Green
} else {
    Write-Host "  ✓ No changes to commit" -ForegroundColor Green
}

Write-Host "[2/6] Pushing to GitHub..." -ForegroundColor Yellow
git push
Write-Host "  ✓ Pushed to GitHub" -ForegroundColor Green

Write-Host "[3/6] Pulling on server..." -ForegroundColor Yellow
$pullCmd = "cd /home/$User/GeoMaxima && git pull"
ssh "${User}@${Host}" $pullCmd
Write-Host "  ✓ Server updated from GitHub" -ForegroundColor Green

Write-Host "[4/6] Deploying features..." -ForegroundColor Yellow
$deployCmd = @"
cd /home/$User/GeoMaxima && \
sudo rsync -av --delete features/ /home/$User/rtkbase/web_app/geomaxima/features/ && \
sudo rsync -av --delete templates/ /home/$User/rtkbase/web_app/templates/ && \
sudo chown -R ${User}:${User} /home/$User/rtkbase/web_app/geomaxima && \
sudo chown -R ${User}:${User} /home/$User/rtkbase/web_app/templates/geomaxima
"@
ssh "${User}@${Host}" $deployCmd
Write-Host "  ✓ Features and templates deployed" -ForegroundColor Green

Write-Host "[5/6] Installing polkit rules..." -ForegroundColor Yellow
$polkitCmd = @"
if [ -f /home/$User/GeoMaxima/tools/polkit/10-rtkbase-gnss-config.rules ]; then
    sudo cp /home/$User/GeoMaxima/tools/polkit/10-rtkbase-gnss-config.rules /etc/polkit-1/rules.d/
    sudo systemctl restart polkit
    echo 'Polkit rules installed'
else
    echo 'Polkit rules not found, skipping'
fi
"@
ssh "${User}@${Host}" $polkitCmd
Write-Host "  ✓ Polkit rules updated" -ForegroundColor Green

Write-Host "[6/6] Restarting web service..." -ForegroundColor Yellow
$restartCmd = "sudo systemctl restart rtkbase_web.service"
ssh "${User}@${Host}" $restartCmd
Start-Sleep -Seconds 2
Write-Host "  ✓ Service restarted" -ForegroundColor Green

Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
Write-Host "  ✓ Deployment Complete!" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Access GeoMaxima at: http://${Host}/geomaxima" -ForegroundColor Cyan
Write-Host ""
