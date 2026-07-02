// WireGuard VPN Client Management

document.addEventListener('DOMContentLoaded', function() {
    loadWireGuardStatus();
    setupEventListeners();
    
    // Refresh status every 10 seconds
    setInterval(loadWireGuardStatus, 10000);
});

function setupEventListeners() {
    document.getElementById('btn-connect')?.addEventListener('click', connectWireGuard);
    document.getElementById('btn-disconnect')?.addEventListener('click', disconnectWireGuard);
    document.getElementById('btn-enable-autostart')?.addEventListener('click', enableAutostart);
    document.getElementById('btn-disable-autostart')?.addEventListener('click', disableAutostart);
    document.getElementById('btn-save-config')?.addEventListener('click', saveConfiguration);
}

function loadWireGuardStatus() {
    fetch('/geomaxima/api/wireguard/status')
        .then(response => response.json())
        .then(data => {
            updateStatusUI(data);
            updateButtons(data);
        })
        .catch(error => {
            console.error('Error loading status:', error);
            showError('Failed to load WireGuard status');
        });
}

function updateStatusUI(data) {
    const statusSection = document.getElementById('status-section');
    
    if (data.status === 'not_installed') {
        statusSection.innerHTML = `
            <div class="alert alert-warning">
                <h6>WireGuard Not Installed</h6>
                <p>WireGuard is not installed on this system.</p>
                <button class="btn btn-primary" onclick="installWireGuard()">Install WireGuard</button>
            </div>
        `;
        return;
    }
    
    const statusBadge = data.connected ? 
        '<span class="badge badge-success">Connected</span>' : 
        '<span class="badge badge-secondary">Disconnected</span>';
    
    const autostartBadge = data.enabled ?
        '<span class="badge badge-primary">Enabled</span>' :
        '<span class="badge badge-secondary">Disabled</span>';
    
    statusSection.innerHTML = `
        <table class="table table-sm mb-0">
            <tr>
                <td><b>Status:</b></td>
                <td>${statusBadge}</td>
            </tr>
            <tr>
                <td><b>Autostart:</b></td>
                <td>${autostartBadge}</td>
            </tr>
            <tr>
                <td><b>Interface:</b></td>
                <td>${data.interface || 'wg0'}</td>
            </tr>
            ${data.endpoint ? `
            <tr>
                <td><b>Endpoint:</b></td>
                <td>${data.endpoint}</td>
            </tr>
            ` : ''}
            ${data.transfer_rx ? `
            <tr>
                <td><b>Data Received:</b></td>
                <td>${formatBytes(data.transfer_rx)}</td>
            </tr>
            ` : ''}
        </table>
    `;
    
    updateConfigSection(data.config_exists);
}

function updateConfigSection(configExists) {
    const configSection = document.getElementById('config-section');
    
    if (configExists) {
        configSection.innerHTML = `
            <p class="mb-2">Configuration file exists: <span class="badge badge-success">Yes</span></p>
            <button class="btn btn-sm btn-primary" data-toggle="modal" data-target="#configModal">
                Edit Configuration
            </button>
            <button class="btn btn-sm btn-danger" onclick="deleteConfiguration()">
                Delete Configuration
            </button>
        `;
    } else {
        configSection.innerHTML = `
            <p class="mb-2">No configuration found.</p>
            <button class="btn btn-sm btn-primary" data-toggle="modal" data-target="#configModal">
                Add Configuration
            </button>
        `;
    }
}

function updateButtons(data) {
    const btnConnect = document.getElementById('btn-connect');
    const btnDisconnect = document.getElementById('btn-disconnect');
    const btnEnableAutostart = document.getElementById('btn-enable-autostart');
    const btnDisableAutostart = document.getElementById('btn-disable-autostart');
    
    if (data.status === 'not_installed' || !data.config_exists) {
        btnConnect.disabled = true;
        btnDisconnect.disabled = true;
        btnEnableAutostart.disabled = true;
        btnDisableAutostart.disabled = true;
        return;
    }
    
    btnConnect.disabled = data.connected;
    btnDisconnect.disabled = !data.connected;
    btnEnableAutostart.disabled = data.enabled;
    btnDisableAutostart.disabled = !data.enabled;
}

function connectWireGuard() {
    if (!confirm('Connect to WireGuard VPN?')) return;
    
    fetch('/geomaxima/api/wireguard/connect', { method: 'POST' })
        .then(response => response.json())
        .then(data => {
            if (data.success) {
                showSuccess('WireGuard connected successfully');
                loadWireGuardStatus();
            } else {
                showError(data.message || 'Failed to connect');
            }
        })
        .catch(error => showError('Error connecting: ' + error));
}

function disconnectWireGuard() {
    if (!confirm('Disconnect from WireGuard VPN?')) return;
    
    fetch('/geomaxima/api/wireguard/disconnect', { method: 'POST' })
        .then(response => response.json())
        .then(data => {
            if (data.success) {
                showSuccess('WireGuard disconnected');
                loadWireGuardStatus();
            } else {
                showError(data.message || 'Failed to disconnect');
            }
        })
        .catch(error => showError('Error disconnecting: ' + error));
}

function enableAutostart() {
    fetch('/geomaxima/api/wireguard/enable', { method: 'POST' })
        .then(response => response.json())
        .then(data => {
            if (data.success) {
                showSuccess('Autostart enabled');
                loadWireGuardStatus();
            } else {
                showError(data.message || 'Failed to enable autostart');
            }
        })
        .catch(error => showError('Error: ' + error));
}

function disableAutostart() {
    fetch('/geomaxima/api/wireguard/disable', { method: 'POST' })
        .then(response => response.json())
        .then(data => {
            if (data.success) {
                showSuccess('Autostart disabled');
                loadWireGuardStatus();
            } else {
                showError(data.message || 'Failed to disable autostart');
            }
        })
        .catch(error => showError('Error: ' + error));
}

function saveConfiguration() {
    const configText = document.getElementById('wg-config-text').value.trim();
    
    if (!configText) {
        showError('Please enter a configuration');
        return;
    }
    
    fetch('/geomaxima/api/wireguard/config', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ config: configText })
    })
    .then(response => response.json())
    .then(data => {
        if (data.success) {
            showSuccess('Configuration saved');
            $('#configModal').modal('hide');
            loadWireGuardStatus();
        } else {
            showError(data.message || 'Failed to save configuration');
        }
    })
    .catch(error => showError('Error saving: ' + error));
}

function deleteConfiguration() {
    if (!confirm('Delete WireGuard configuration? This will also disconnect if connected.')) return;
    
    fetch('/geomaxima/api/wireguard/config', { method: 'DELETE' })
        .then(response => response.json())
        .then(data => {
            if (data.success) {
                showSuccess('Configuration deleted');
                loadWireGuardStatus();
            } else {
                showError(data.message || 'Failed to delete');
            }
        })
        .catch(error => showError('Error: ' + error));
}

function installWireGuard() {
    if (!confirm('Install WireGuard? This requires root privileges.')) return;
    
    showInfo('Installing WireGuard... This may take a few minutes.');
    
    fetch('/geomaxima/api/wireguard/install', { method: 'POST' })
        .then(response => response.json())
        .then(data => {
            if (data.success) {
                showSuccess('WireGuard installed successfully');
                setTimeout(loadWireGuardStatus, 2000);
            } else {
                showError(data.message || 'Installation failed');
            }
        })
        .catch(error => showError('Error: ' + error));
}

// Utility functions
function formatBytes(bytes) {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return Math.round(bytes / Math.pow(k, i) * 100) / 100 + ' ' + sizes[i];
}

function showSuccess(message) {
    showNotification(message, 'success');
}

function showError(message) {
    showNotification(message, 'danger');
}

function showInfo(message) {
    showNotification(message, 'info');
}

function showNotification(message, type) {
    const alert = document.createElement('div');
    alert.className = `alert alert-${type} alert-dismissible fade show`;
    alert.style.position = 'fixed';
    alert.style.top = '20px';
    alert.style.right = '20px';
    alert.style.zIndex = '9999';
    alert.style.minWidth = '300px';
    alert.innerHTML = `
        ${message}
        <button type="button" class="close" data-dismiss="alert">
            <span>&times;</span>
        </button>
    `;
    document.body.appendChild(alert);
    
    setTimeout(() => alert.remove(), 5000);
}
