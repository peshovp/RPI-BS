// GeoMaxima Dashboard JavaScript

document.addEventListener('DOMContentLoaded', function() {
    console.log('GeoMaxima Dashboard loaded');
    
    // Auto-refresh status every 30 seconds
    setInterval(refreshStatus, 30000);
});

function refreshStatus() {
    fetch('/geomaxima/api/status')
        .then(response => response.json())
        .then(data => {
            console.log('Status:', data);
            // Update UI if needed
        })
        .catch(error => console.error('Error fetching status:', error));
}

// Utility function to show notifications
function showNotification(message, type = 'info') {
    // Simple notification system
    const alert = document.createElement('div');
    alert.className = `alert alert-${type} alert-dismissible fade show`;
    alert.style.position = 'fixed';
    alert.style.top = '20px';
    alert.style.right = '20px';
    alert.style.zIndex = '9999';
    alert.innerHTML = `
        ${message}
        <button type="button" class="close" data-dismiss="alert">
            <span>&times;</span>
        </button>
    `;
    document.body.appendChild(alert);
    
    setTimeout(() => alert.remove(), 5000);
}
