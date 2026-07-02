#!/bin/bash
#
# Inject RTCM dropdown into RTKBase settings.html
# This script modifies the RTKBase settings page to add RTCM message presets
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Simple logging functions
log_info() {
    echo "[INFO] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

log_warning() {
    echo "[WARNING] $1" >&2
}

# Find RTKBase settings.html
SETTINGS_PATHS=(
    "/var/www/html/settings.html"
    "$HOME/rtkbase/web_app/templates/settings.html"
    "/home/$(whoami)/rtkbase/web_app/templates/settings.html"
    "/usr/share/nginx/html/settings.html"
    "/home/*/rtkbase/web_app/templates/settings.html"
)

log_info "Searching for settings.html..."
SETTINGS_FILE=""
for path in "${SETTINGS_PATHS[@]}"; do
    # Expand wildcards
    for expanded_path in $path; do
        if [ -f "$expanded_path" ]; then
            SETTINGS_FILE="$expanded_path"
            log_info "✓ Found settings.html at: $SETTINGS_FILE"
            break 2
        else
            log_info "  Not found: $expanded_path"
        fi
    done
done

if [ -z "$SETTINGS_FILE" ]; then
    log_error "settings.html not found in any of the expected locations"
    log_info "Searched in:"
    for path in "${SETTINGS_PATHS[@]}"; do
        log_info "  - $path"
    done
    exit 0  # Don't fail the install, just skip
fi

# Check if already injected
if grep -q "GeoMaxima: RTCM dropdown injected" "$SETTINGS_FILE"; then
    log_info "✓ RTCM dropdown already injected"
    exit 0
fi

# Backup original file (only if backup doesn't exist)
if [ ! -f "${SETTINGS_FILE}.backup" ]; then
    cp "$SETTINGS_FILE" "${SETTINGS_FILE}.backup"
    log_info "Created backup: ${SETTINGS_FILE}.backup"
fi

# JavaScript to inject
read -r -d '' RTCM_JS << 'EOFJS'

<!-- GeoMaxima: RTCM dropdown injected -->
<script>
// GeoMaxima: RTCM Message Presets
(function() {
    console.log('GeoMaxima: Initializing RTCM dropdown...');
    
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
        
        // Find RTCM inputs by ID
        const inputs = ['rtcm_msg_A', 'rtcm_msg_B'];
        
        inputs.forEach(inputId => {
            const input = document.getElementById(inputId);
            if (!input) {
                console.warn('RTCM input not found:', inputId);
                return;
            }
            
            // Create dropdown container
            const container = document.createElement('div');
            container.style.cssText = 'margin-bottom: 10px;';
            
            // Create dropdown
            const select = document.createElement('select');
            select.id = inputId + '_preset';
            select.style.cssText = 'width: 100%; padding: 10px; border: 2px solid #4CAF50; border-radius: 6px; font-size: 14px; background: white; cursor: pointer; box-shadow: 0 2px 4px rgba(0,0,0,0.1);';
            
            // Add options
            let optionsHtml = '<option value="">' + labels.select + '</option>';
            for (const [key, label] of Object.entries(labels)) {
                if (key !== 'select') {
                    optionsHtml += '<option value="' + key + '">' + label + '</option>';
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
                    this.style.boxShadow = '0 0 8px rgba(76, 175, 80, 0.5)';
                    setTimeout(() => {
                        this.style.boxShadow = '0 2px 4px rgba(0,0,0,0.1)';
                    }, 500);
                } else {
                    input.readOnly = false;
                    input.style.backgroundColor = '';
                }
            });
            
            container.appendChild(select);
            
            // Insert before input
            input.parentNode.insertBefore(container, input);
        });
        
        console.log('✓ GeoMaxima: RTCM dropdown ready!');
    }
})();
</script>
EOFJS

# Inject before {% endblock %} in scripts section or before </body>
if grep -q "{% block scripts %}" "$SETTINGS_FILE"; then
    # Jinja2 template - inject before last {% endblock %}
    log_info "Detected Jinja2 template, injecting into scripts block..."
    TMP_FILE="${SETTINGS_FILE}.tmp"
    
    # Find the last {% endblock %} and inject before it
    awk -v js="$RTCM_JS" '
        /{% endblock %}/ {
            if (!injected) {
                # Store the line
                endblock_line = $0
                # Check if this is the last endblock by reading ahead
                while ((getline next_line) > 0) {
                    buffer = buffer next_line "\n"
                }
                # This is the last endblock, inject before it
                print js
                print endblock_line
                printf "%s", buffer
                injected = 1
                next
            }
        }
        { print }
    ' "$SETTINGS_FILE" > "$TMP_FILE"
    
    # Replace original with modified version
    mv "$TMP_FILE" "$SETTINGS_FILE"
    log_info "✓ RTCM dropdown injected into Jinja2 template"
    
elif grep -q "</body>" "$SETTINGS_FILE"; then
    # Regular HTML - inject before </body>
    log_info "Detected regular HTML, injecting before </body>..."
    TMP_FILE="${SETTINGS_FILE}.tmp"
    awk -v js="$RTCM_JS" '
        /<\/body>/ {
            print js
        }
        { print }
    ' "$SETTINGS_FILE" > "$TMP_FILE"
    
    # Replace original with modified version
    mv "$TMP_FILE" "$SETTINGS_FILE"
    log_info "✓ RTCM dropdown injected into HTML"
else
    log_warning "Neither {% endblock %} nor </body> tag found in settings.html"
    exit 1
fi

log_info "Done!"
