"""
RTKBase Settings Proxy
Proxies RTKBase settings.html and injects RTCM dropdown
"""

from flask import Blueprint, Response, request
import requests
import logging
from pathlib import Path

logger = logging.getLogger(__name__)

rtkbase_proxy_bp = Blueprint('rtkbase_proxy', __name__)


# RTCM Dropdown JavaScript
RTCM_DROPDOWN_JS = """
<script>
// GeoMaxima: RTCM Message Presets
(function() {
    console.log('GeoMaxima: Injecting RTCM dropdown...');
    
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initRtcmDropdowns);
    } else {
        initRtcmDropdowns();
    }
    
    function initRtcmDropdowns() {
        const rtcmPresets = {
            msm4: '1005(10),1006,1033(10),1074,1084,1094,1124,1230',
            msm5: '1005(10),1006,1033(10),1075,1085,1095,1125,1230',
            msm7: '1005(10),1006,1033(10),1077,1087,1097,1127,1230',
            msm4_cmr: '1005(10),1006,1019,1020,1033(10),1042,1045,1046,1074,1084,1094,1124,1230',
            msm5_cmr: '1005(10),1006,1019,1020,1033(10),1042,1045,1046,1075,1085,1095,1125,1230',
            msm7_cmr: '1005(10),1006,1019,1020,1033(10),1042,1045,1046,1077,1087,1097,1127,1230'
        };
        
        const labels = {
            select: '-- Select RTCM preset --',
            msm4: '📡 MSM4 - Low Bandwidth (~400 bytes/s)',
            msm5: '📡 MSM5 - Balanced (~800 bytes/s)',
            msm7: '📡 MSM7 - High Precision (~1200 bytes/s)',
            msm4_cmr: '🛰️ MSM4 + CMR (GPS L1/L2)',
            msm5_cmr: '🛰️ MSM5 + CMR',
            msm7_cmr: '🛰️ MSM7 + CMR'
        };
        
        // Find RTCM inputs
        const inputs = ['rtcm_msg_A', 'rtcm_msg_B'];
        
        inputs.forEach(inputId => {
            const input = document.getElementById(inputId);
            if (!input) return;
            
            // Create dropdown container
            const container = document.createElement('div');
            container.style.cssText = 'margin-bottom: 10px;';
            
            // Create dropdown
            const select = document.createElement('select');
            select.id = inputId + '_preset';
            select.style.cssText = 'width: 100%; padding: 8px; border: 2px solid #4CAF50; border-radius: 6px; font-size: 14px; background: white; cursor: pointer;';
            
            // Add options
            let optionsHtml = `<option value="">${labels.select}</option>`;
            for (const [key, label] of Object.entries(labels)) {
                if (key !== 'select') {
                    optionsHtml += `<option value="${key}">${label}</option>`;
                }
            }
            select.innerHTML = optionsHtml;
            
            // Detect current preset
            const currentValue = input.value.trim();
            for (const [key, value] of Object.entries(rtcmPresets)) {
                if (value === currentValue) {
                    select.value = key;
                    input.readOnly = true;
                    input.style.backgroundColor = '#f0f0f0';
                    break;
                }
            }
            
            // Handle change
            select.addEventListener('change', function() {
                if (this.value) {
                    input.value = rtcmPresets[this.value];
                    input.readOnly = true;
                    input.style.backgroundColor = '#f0f0f0';
                    
                    // Visual feedback
                    this.style.borderColor = '#4CAF50';
                    setTimeout(() => {
                        this.style.borderColor = '#4CAF50';
                    }, 300);
                } else {
                    input.readOnly = false;
                    input.style.backgroundColor = '';
                }
            });
            
            container.appendChild(select);
            
            // Insert before input
            input.parentNode.insertBefore(container, input);
        });
        
        console.log('✓ GeoMaxima: RTCM dropdown injected!');
    }
})();
</script>
"""


@rtkbase_proxy_bp.route('/settings.html')
def proxy_settings():
    """Proxy RTKBase settings.html and inject RTCM dropdown"""
    try:
        # Try to read from RTKBase web app directory
        settings_paths = [
            Path('/var/www/html/settings.html'),
            Path.home() / 'rtkbase' / 'web_app' / 'templates' / 'settings.html',
        ]
        
        settings_html = None
        for path in settings_paths:
            if path.exists():
                logger.info(f"Reading settings.html from {path}")
                with open(path, 'r', encoding='utf-8') as f:
                    settings_html = f.read()
                break
        
        if not settings_html:
            logger.error("settings.html not found")
            return Response("Settings page not found", status=404)
        
        # Inject RTCM dropdown JavaScript
        if '</body>' in settings_html and 'GeoMaxima: RTCM dropdown injected' not in settings_html:
            settings_html = settings_html.replace('</body>', RTCM_DROPDOWN_JS + '\n</body>')
            logger.info("✓ RTCM dropdown injected into settings.html")
        
        return Response(settings_html, mimetype='text/html')
        
    except Exception as e:
        logger.error(f"Failed to proxy settings.html: {e}", exc_info=True)
        return Response(f"Error loading settings: {e}", status=500)


def register_rtkbase_proxy(app):
    """Register RTKBase proxy blueprint"""
    app.register_blueprint(rtkbase_proxy_bp)
    logger.info("✓ RTKBase settings proxy registered")
