"""
System Settings Feature
Full raspi-config control through web interface

This feature allows:
- Hostname management
- WiFi configuration
- Locale settings (timezone, keyboard layout)
- Interface settings (SSH, VNC, SPI, I2C, Serial)
- Performance settings (overclock, memory split)
- Display settings (resolution, orientation)
- Boot options
- Update raspi-config
"""

from flask import render_template, jsonify, request
import logging
import subprocess
import re
import os
from pathlib import Path

logger = logging.getLogger(__name__)


def run_command(cmd, shell=False):
    """Execute shell command and return output"""
    try:
        if isinstance(cmd, str) and not shell:
            cmd = cmd.split()
        
        result = subprocess.run(
            cmd,
            shell=shell,
            capture_output=True,
            text=True,
            timeout=30
        )
        
        return {
            'success': result.returncode == 0,
            'stdout': result.stdout.strip(),
            'stderr': result.stderr.strip(),
            'returncode': result.returncode
        }
    except subprocess.TimeoutExpired:
        return {'success': False, 'error': 'Command timeout'}
    except Exception as e:
        return {'success': False, 'error': str(e)}


def get_hostname():
    """Get current hostname"""
    try:
        with open('/etc/hostname', 'r') as f:
            return f.read().strip()
    except Exception as e:
        logger.error(f"Failed to read hostname: {e}")
        return None


def set_hostname(new_hostname):
    """Set new hostname"""
    try:
        # Validate hostname
        if not re.match(r'^[a-zA-Z0-9-]+$', new_hostname):
            return False, "Invalid hostname format (use only letters, numbers, hyphens)"
        
        if len(new_hostname) > 63:
            return False, "Hostname too long (max 63 characters)"
        
        # Update /etc/hostname
        cmd = f"echo '{new_hostname}' | sudo tee /etc/hostname > /dev/null"
        result = run_command(cmd, shell=True)
        
        if not result['success']:
            return False, f"Failed to update /etc/hostname: {result.get('stderr', '')}"
        
        # Update /etc/hosts
        old_hostname = get_hostname()
        if old_hostname:
            cmd = f"sudo sed -i 's/127.0.1.1.*{old_hostname}/127.0.1.1\\t{new_hostname}/g' /etc/hosts"
            run_command(cmd, shell=True)
        
        # Apply hostname change
        cmd = f"sudo hostnamectl set-hostname {new_hostname}"
        result = run_command(cmd, shell=True)
        
        if result['success']:
            return True, "Hostname updated successfully (reboot required)"
        else:
            return False, f"Failed to apply hostname: {result.get('stderr', '')}"
        
    except Exception as e:
        logger.error(f"Failed to set hostname: {e}")
        return False, str(e)


def get_timezone():
    """Get current timezone"""
    result = run_command("timedatectl show -p Timezone --value")
    if result['success']:
        return result['stdout']
    return None


def set_timezone(timezone):
    """Set timezone"""
    cmd = f"sudo timedatectl set-timezone {timezone}"
    result = run_command(cmd, shell=True)
    return result['success'], result.get('stderr', 'Success')


def get_locale():
    """Get current locale"""
    result = run_command("locale | grep LANG=")
    if result['success']:
        match = re.search(r'LANG=(.+)', result['stdout'])
        if match:
            return match.group(1)
    return None


def get_wifi_country():
    """Get WiFi country code"""
    try:
        result = run_command("sudo raspi-config nonint get_wifi_country", shell=True)
        if result['success'] and result['stdout']:
            return result['stdout']
        return None
    except:
        return None


def set_wifi_country(country_code):
    """Set WiFi country code"""
    cmd = f"sudo raspi-config nonint do_wifi_country {country_code}"
    result = run_command(cmd, shell=True)
    return result['success'], result.get('stderr', 'Success')


def get_interface_status(interface):
    """
    Get status of interface (SSH, VNC, SPI, I2C, Serial, etc.)
    Returns: 0 = enabled, 1 = disabled
    """
    interface_map = {
        'ssh': 'get_ssh',
        'vnc': 'get_vnc',
        'spi': 'get_spi',
        'i2c': 'get_i2c',
        'serial': 'get_serial',
        'serial_hw': 'get_serial_hw',
        'camera': 'get_camera',
        'onewire': 'get_onewire',
        'rgpio': 'get_rgpio'
    }
    
    if interface not in interface_map:
        return None
    
    cmd = f"sudo raspi-config nonint {interface_map[interface]}"
    result = run_command(cmd, shell=True)
    
    if result['success']:
        try:
            return int(result['stdout'].strip())
        except:
            return None
    return None


def set_interface_status(interface, enable):
    """
    Enable/disable interface
    enable: True/False
    """
    interface_map = {
        'ssh': 'do_ssh',
        'vnc': 'do_vnc',
        'spi': 'do_spi',
        'i2c': 'do_i2c',
        'serial': 'do_serial',
        'serial_hw': 'do_serial_hw',
        'camera': 'do_camera',
        'onewire': 'do_onewire',
        'rgpio': 'do_rgpio'
    }
    
    if interface not in interface_map:
        return False, "Unknown interface"
    
    value = "0" if enable else "1"  # 0 = enable, 1 = disable
    cmd = f"sudo raspi-config nonint {interface_map[interface]} {value}"
    result = run_command(cmd, shell=True)
    
    return result['success'], result.get('stderr', 'Success')


def get_memory_split():
    """Get GPU memory split"""
    try:
        with open('/boot/config.txt', 'r') as f:
            content = f.read()
            match = re.search(r'gpu_mem=(\d+)', content)
            if match:
                return int(match.group(1))
        return 64  # Default
    except:
        return None


def set_memory_split(gpu_mem):
    """Set GPU memory split"""
    cmd = f"sudo raspi-config nonint do_memory_split {gpu_mem}"
    result = run_command(cmd, shell=True)
    return result['success'], result.get('stderr', 'Success')


def get_boot_option():
    """Get boot option (console vs desktop)"""
    result = run_command("sudo raspi-config nonint get_boot_cli", shell=True)
    if result['success']:
        return result['stdout'].strip()
    return None


def get_wifi_networks():
    """Scan for available WiFi networks"""
    try:
        result = run_command("sudo iwlist wlan0 scan | grep -E 'ESSID|Quality|Encryption'", shell=True)
        if result['success']:
            # Parse output to extract network info
            networks = []
            lines = result['stdout'].split('\n')
            
            current = {}
            for line in lines:
                if 'ESSID:' in line:
                    if current:
                        networks.append(current)
                    essid = re.search(r'ESSID:"(.+)"', line)
                    current = {'ssid': essid.group(1) if essid else 'Hidden'}
                elif 'Quality=' in line:
                    quality = re.search(r'Quality=(\d+)/(\d+)', line)
                    if quality:
                        current['signal'] = int(int(quality.group(1)) / int(quality.group(2)) * 100)
                elif 'Encryption key:' in line:
                    current['encrypted'] = 'on' in line
            
            if current:
                networks.append(current)
            
            return networks
        return []
    except Exception as e:
        logger.error(f"Failed to scan WiFi: {e}")
        return []


def get_current_wifi():
    """Get currently connected WiFi SSID"""
    result = run_command("iwgetid -r")
    if result['success'] and result['stdout']:
        return result['stdout']
    return None


def connect_wifi(ssid, password=None):
    """Connect to WiFi network"""
    try:
        # Create wpa_supplicant config
        if password:
            cmd = f'wpa_passphrase "{ssid}" "{password}" | sudo tee -a /etc/wpa_supplicant/wpa_supplicant.conf > /dev/null'
        else:
            # Open network
            config = f'\nnetwork={{\n    ssid="{ssid}"\n    key_mgmt=NONE\n}}\n'
            cmd = f"echo '{config}' | sudo tee -a /etc/wpa_supplicant/wpa_supplicant.conf > /dev/null"
        
        result = run_command(cmd, shell=True)
        
        if result['success']:
            # Reconfigure wpa_supplicant
            run_command("sudo wpa_cli -i wlan0 reconfigure", shell=True)
            return True, "WiFi configured successfully"
        else:
            return False, result.get('stderr', 'Failed to configure WiFi')
        
    except Exception as e:
        return False, str(e)


def get_system_info():
    """Get system information"""
    info = {}
    
    # Raspberry Pi model
    try:
        with open('/proc/device-tree/model', 'r') as f:
            info['model'] = f.read().strip().replace('\x00', '')
    except:
        info['model'] = 'Unknown'
    
    # OS version
    result = run_command("cat /etc/os-release | grep PRETTY_NAME", shell=True)
    if result['success']:
        match = re.search(r'PRETTY_NAME="(.+)"', result['stdout'])
        if match:
            info['os'] = match.group(1)
    
    # Kernel version
    result = run_command("uname -r")
    if result['success']:
        info['kernel'] = result['stdout']
    
    # CPU temperature
    try:
        with open('/sys/class/thermal/thermal_zone0/temp', 'r') as f:
            temp = int(f.read().strip()) / 1000.0
            info['cpu_temp'] = f"{temp:.1f}°C"
    except:
        info['cpu_temp'] = 'N/A'
    
    # Uptime
    result = run_command("uptime -p")
    if result['success']:
        info['uptime'] = result['stdout']
    
    return info


def register_routes(app, gm_blueprint):
    """Register System Settings routes"""
    
    @gm_blueprint.route('/system-settings')
    def system_settings_page():
        """System Settings configuration page"""
        try:
            system_info = get_system_info()
            hostname = get_hostname()
            timezone = get_timezone()
            locale = get_locale()
            wifi_country = get_wifi_country()
            current_wifi = get_current_wifi()
            
            # Get interface statuses
            interfaces = {}
            for iface in ['ssh', 'vnc', 'spi', 'i2c', 'serial', 'camera']:
                status = get_interface_status(iface)
                interfaces[iface] = (status == 0)  # 0 = enabled
            
            return render_template(
                'geomaxima/system_settings.html',
                feature_enabled=True,
                system_info=system_info,
                hostname=hostname,
                timezone=timezone,
                locale=locale,
                wifi_country=wifi_country,
                current_wifi=current_wifi,
                interfaces=interfaces
            )
        except Exception as e:
            logger.error(f"System settings page error: {e}")
            return render_template(
                'geomaxima/system_settings.html',
                feature_enabled=False,
                error=str(e)
            )
    
    
    @gm_blueprint.route('/api/system/hostname', methods=['GET', 'POST'])
    def api_hostname():
        """Get or set hostname"""
        if request.method == 'GET':
            hostname = get_hostname()
            return jsonify({
                'success': True,
                'hostname': hostname
            })
        else:
            data = request.get_json() or {}
            new_hostname = data.get('hostname', '').strip()
            
            if not new_hostname:
                return jsonify({'success': False, 'error': 'Hostname required'}), 400
            
            success, message = set_hostname(new_hostname)
            
            if success:
                return jsonify({'success': True, 'message': message})
            else:
                return jsonify({'success': False, 'error': message}), 500
    
    
    @gm_blueprint.route('/api/system/timezone', methods=['GET', 'POST'])
    def api_timezone():
        """Get or set timezone"""
        if request.method == 'GET':
            timezone = get_timezone()
            return jsonify({
                'success': True,
                'timezone': timezone
            })
        else:
            data = request.get_json() or {}
            timezone = data.get('timezone', '').strip()
            
            if not timezone:
                return jsonify({'success': False, 'error': 'Timezone required'}), 400
            
            success, message = set_timezone(timezone)
            
            if success:
                return jsonify({'success': True, 'message': message})
            else:
                return jsonify({'success': False, 'error': message}), 500
    
    
    @gm_blueprint.route('/api/system/wifi-country', methods=['GET', 'POST'])
    def api_wifi_country():
        """Get or set WiFi country"""
        if request.method == 'GET':
            country = get_wifi_country()
            return jsonify({
                'success': True,
                'country': country
            })
        else:
            data = request.get_json() or {}
            country = data.get('country', '').strip()
            
            if not country or len(country) != 2:
                return jsonify({'success': False, 'error': 'Valid 2-letter country code required'}), 400
            
            success, message = set_wifi_country(country.upper())
            
            if success:
                return jsonify({'success': True, 'message': message})
            else:
                return jsonify({'success': False, 'error': message}), 500
    
    
    @gm_blueprint.route('/api/system/interface', methods=['POST'])
    def api_interface():
        """Enable/disable interface"""
        data = request.get_json() or {}
        interface = data.get('interface', '').strip()
        enable = data.get('enable', False)
        
        if not interface:
            return jsonify({'success': False, 'error': 'Interface name required'}), 400
        
        success, message = set_interface_status(interface, enable)
        
        if success:
            return jsonify({
                'success': True,
                'message': f"{'Enabled' if enable else 'Disabled'} {interface.upper()}"
            })
        else:
            return jsonify({'success': False, 'error': message}), 500
    
    
    @gm_blueprint.route('/api/system/memory-split', methods=['GET', 'POST'])
    def api_memory_split():
        """Get or set GPU memory split"""
        if request.method == 'GET':
            gpu_mem = get_memory_split()
            return jsonify({
                'success': True,
                'gpu_mem': gpu_mem
            })
        else:
            data = request.get_json() or {}
            gpu_mem = data.get('gpu_mem')
            
            try:
                gpu_mem = int(gpu_mem)
                if gpu_mem not in [16, 32, 64, 128, 256, 512]:
                    raise ValueError("Invalid value")
            except:
                return jsonify({'success': False, 'error': 'Valid GPU memory value required (16, 32, 64, 128, 256, 512)'}), 400
            
            success, message = set_memory_split(gpu_mem)
            
            if success:
                return jsonify({'success': True, 'message': f'GPU memory set to {gpu_mem}MB (reboot required)'})
            else:
                return jsonify({'success': False, 'error': message}), 500
    
    
    @gm_blueprint.route('/api/system/wifi/scan', methods=['POST'])
    def api_wifi_scan():
        """Scan for WiFi networks"""
        networks = get_wifi_networks()
        return jsonify({
            'success': True,
            'networks': networks
        })
    
    
    @gm_blueprint.route('/api/system/wifi/connect', methods=['POST'])
    def api_wifi_connect():
        """Connect to WiFi network"""
        data = request.get_json() or {}
        ssid = data.get('ssid', '').strip()
        password = data.get('password', '').strip()
        
        if not ssid:
            return jsonify({'success': False, 'error': 'SSID required'}), 400
        
        success, message = connect_wifi(ssid, password if password else None)
        
        if success:
            return jsonify({'success': True, 'message': message})
        else:
            return jsonify({'success': False, 'error': message}), 500
    
    
    @gm_blueprint.route('/api/system/reboot', methods=['POST'])
    def api_reboot():
        """Reboot system"""
        try:
            # Schedule reboot in 5 seconds
            subprocess.Popen(['sudo', 'shutdown', '-r', '+0.1'], 
                           stdout=subprocess.DEVNULL, 
                           stderr=subprocess.DEVNULL)
            
            return jsonify({
                'success': True,
                'message': 'System rebooting in 5 seconds...'
            })
        except Exception as e:
            logger.error(f"Failed to reboot: {e}")
            return jsonify({'success': False, 'error': str(e)}), 500
    
    
    @gm_blueprint.route('/api/system/shutdown', methods=['POST'])
    def api_shutdown():
        """Shutdown system"""
        try:
            # Schedule shutdown in 5 seconds
            subprocess.Popen(['sudo', 'shutdown', '-h', '+0.1'], 
                           stdout=subprocess.DEVNULL, 
                           stderr=subprocess.DEVNULL)
            
            return jsonify({
                'success': True,
                'message': 'System shutting down in 5 seconds...'
            })
        except Exception as e:
            logger.error(f"Failed to shutdown: {e}")
            return jsonify({'success': False, 'error': str(e)}), 500
    
    
    logger.info("System Settings routes registered")
