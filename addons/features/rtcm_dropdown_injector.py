"""
RTCM Dropdown Injector
Injects RTCM message preset dropdown into RTKBase settings page
"""

from flask import Blueprint, render_template_string
import logging

logger = logging.getLogger(__name__)

# JavaScript code to inject
RTCM_DROPDOWN_JS = """
<script>
// RTCM Message Presets - Injected by GeoMaxima
(function() {
    // Wait for DOM ready
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
        
        // Find RTCM input fields
        const rtcmInputA = document.getElementById('rtcm_msg_A');
        const rtcmInputB = document.getElementById('rtcm_msg_B');
        
        if (rtcmInputA) {
            injectDropdown(rtcmInputA, 'A', rtcmPresets);
        }
        
        if (rtcmInputB) {
            injectDropdown(rtcmInputB, 'B', rtcmPresets);
        }
    }
    
    function injectDropdown(input, suffix, presets) {
        // Create dropdown
        const select = document.createElement('select');
        select.id = 'rtcm_msg_' + suffix + '_preset';
        select.className = 'form-control mb-2';
        select.style.marginBottom = '10px';
        
        // Add options
        const options = [
            { value: '', text: '-- Select RTCM Preset --' },
            { value: 'msm4', text: 'MSM4 - Compact (300-500 bytes/s)' },
            { value: 'msm5', text: 'MSM5 - Full Precision (500-800 bytes/s) ⭐ Recommended' },
            { value: 'msm7', text: 'MSM7 - High Resolution (800-1200 bytes/s)' },
            { value: 'msm4_cmr', text: 'MSM4 + CMR - Compact + Legacy Support' },
            { value: 'msm5_cmr', text: 'MSM5 + CMR - Full + Legacy Support' },
            { value: 'msm7_cmr', text: 'MSM7 + CMR - Maximum Compatibility' },
            { value: 'custom', text: 'Custom (Manual Entry)' }
        ];
        
        options.forEach(opt => {
            const option = document.createElement('option');
            option.value = opt.value;
            option.textContent = opt.text;
            select.appendChild(option);
        });
        
        // Insert before input
        input.parentNode.insertBefore(select, input);
        
        // Update help text
        const helpText = input.nextElementSibling;
        if (helpText && helpText.classList.contains('form-text')) {
            helpText.innerHTML = '<strong>Preset Info:</strong> MSM4=Compact/Fast, MSM5=Balanced (recommended), MSM7=High Accuracy. CMR adds ephemeris for legacy receivers. <a href="/geomaxima/rtcm-info" target="_blank">Learn more</a>';
        }
        
        // Handle dropdown change
        select.addEventListener('change', function() {
            if (this.value && this.value !== 'custom' && presets[this.value]) {
                input.value = presets[this.value];
                input.readOnly = true;
                input.style.backgroundColor = '#e9ecef';
                input.style.cursor = 'not-allowed';
            } else {
                input.readOnly = false;
                input.style.backgroundColor = '';
                input.style.cursor = '';
            }
        });
        
        // Auto-detect current preset
        if (input.value) {
            for (const [key, value] of Object.entries(presets)) {
                if (input.value === value) {
                    select.value = key;
                    input.readOnly = true;
                    input.style.backgroundColor = '#e9ecef';
                    input.style.cursor = 'not-allowed';
                    break;
                }
            }
        }
        
        console.log('GeoMaxima: RTCM dropdown injected for ' + suffix);
    }
})();
</script>
"""

def register_rtcm_injector(app):
    """Register RTCM dropdown injector in RTKBase"""
    
    @app.after_request
    def inject_rtcm_dropdown(response):
        """Inject RTCM dropdown JavaScript into settings page"""
        try:
            # Only inject on settings page
            if (response.status_code == 200 and 
                response.content_type and 
                'text/html' in response.content_type and
                b'/settings.html' in response.get_data() or b'rtcm_msg_A' in response.get_data()):
                
                data = response.get_data(as_text=True)
                
                # Check if not already injected
                if 'GeoMaxima: RTCM dropdown injected' not in data and 'rtcm_msg_A' in data:
                    # Inject before </body>
                    if '</body>' in data:
                        data = data.replace('</body>', RTCM_DROPDOWN_JS + '\n</body>')
                        response.set_data(data)
                        logger.info("RTCM dropdown injected into settings page")
        except Exception as e:
            logger.error(f"Failed to inject RTCM dropdown: {e}")
        
        return response
    
    logger.info("RTCM dropdown injector registered")
