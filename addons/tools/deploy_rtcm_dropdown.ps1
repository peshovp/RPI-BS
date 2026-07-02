# Deploy RTCM Dropdown Menu to BS-Aheloy
# This script updates settings.html with RTCM message presets

$SERVER = "192.168.1.14"
$USER = "basegnss"
$SETTINGS_FILE = "/var/www/html/web_app/templates/settings.html"
$BACKUP_FILE = "/var/www/html/web_app/templates/settings.html.backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

Write-Host "Deploying RTCM Dropdown Menu to BS-Aheloy..." -ForegroundColor Cyan

# Create backup
Write-Host "`nCreating backup..." -ForegroundColor Yellow
ssh "${USER}@${SERVER}" "sudo cp $SETTINGS_FILE $BACKUP_FILE"

# Copy new settings.html
Write-Host "`nUploading new settings.html..." -ForegroundColor Yellow
scp E:\Projects\rtkbase-2.7.0\web_app\templates\settings.html "${USER}@${SERVER}:/tmp/settings_new.html"

# Move to correct location
ssh "${USER}@${SERVER}" "sudo mv /tmp/settings_new.html $SETTINGS_FILE"

# Set permissions
ssh "${USER}@${SERVER}" "sudo chown www-data:www-data $SETTINGS_FILE"
ssh "${USER}@${SERVER}" "sudo chmod 644 $SETTINGS_FILE"

# Restart web service
Write-Host "`nRestarting rtkbase_web service..." -ForegroundColor Yellow
ssh "${USER}@${SERVER}" "sudo systemctl restart rtkbase_web"

# Wait for service
Start-Sleep -Seconds 5

# Check service status
Write-Host "`nChecking service status..." -ForegroundColor Yellow
ssh "${USER}@${SERVER}" "systemctl is-active rtkbase_web"

Write-Host ""
Write-Host "Deployment completed!" -ForegroundColor Green
Write-Host "Backup saved to: $BACKUP_FILE" -ForegroundColor Gray
Write-Host ""
Write-Host "Open http://192.168.1.14/settings.html to test the dropdown menu." -ForegroundColor Cyan
