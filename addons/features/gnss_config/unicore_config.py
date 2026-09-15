"""
Unicore UM980/UM982 Configuration
ASCII protocol implementation
"""

import logging
import serial
import time
from typing import Dict, List, Optional

logger = logging.getLogger(__name__)


class UnicoreConfigurator:
    """UM980/UM982 receiver configuration via ASCII commands"""
    
    # RTCM message configuration
    RTCM_MESSAGES = {
        1005: 'RTCM1005',
        1074: 'RTCM1074',
        1077: 'RTCM1077',
        1084: 'RTCM1084',
        1087: 'RTCM1087',
        1094: 'RTCM1094',
        1097: 'RTCM1097',
        1124: 'RTCM1124',
        1127: 'RTCM1127',
        1230: 'RTCM1230'
    }
    
    def __init__(self, port: str, baudrate: int = 115200):
        """
        Initialize Unicore configurator
        
        Args:
            port: Serial port path
            baudrate: Initial baudrate
        """
        self.port = port
        self.baudrate = baudrate
        self.serial = None
    
    def connect(self) -> bool:
        """Connect to receiver"""
        try:
            self.serial = serial.Serial(
                self.port,
                self.baudrate,
                timeout=2.0,
                write_timeout=2.0
            )
            time.sleep(0.5)
            logger.info(f"✓ Connected to Unicore on {self.port}")
            return True
        except Exception as e:
            logger.error(f"Failed to connect: {e}")
            return False
    
    def disconnect(self):
        """Disconnect from receiver"""
        if self.serial and self.serial.is_open:
            self.serial.close()
            logger.info("Disconnected from Unicore")
    
    def send_command(self, command: str, wait_for_ok: bool = True) -> Optional[str]:
        """
        Send ASCII command to receiver
        
        Args:
            command: Command string
            wait_for_ok: Wait for OK response
            
        Returns:
            Response string or None
        """
        if not self.serial or not self.serial.is_open:
            return None
        
        try:
            # Send command
            self.serial.write(f"{command}\r\n".encode('ascii'))
            time.sleep(0.2)
            
            # Read response
            response = ''
            start_time = time.time()
            
            while time.time() - start_time < 2.0:
                if self.serial.in_waiting:
                    chunk = self.serial.read(self.serial.in_waiting).decode('ascii', errors='ignore')
                    response += chunk
                    
                    if wait_for_ok and ('OK' in response or 'ERROR' in response):
                        break
                time.sleep(0.1)
            
            return response.strip()
            
        except Exception as e:
            logger.error(f"Command failed: {e}")
            return None
    
    def get_version(self) -> Optional[Dict]:
        """Get receiver firmware version"""
        response = self.send_command('VERSION')
        
        if response and '#VERSION' in response:
            # Parse version response
            # Format: #VERSIONA,COM1,0,69.5,FINESTEERING,2205,336424.000,02000020,cdba,16248;
            # 28,GPSCARD,"FIRMWARE","UM980","","UM980-1.10","","2023/Mar/20","13:23:55"*4efa20d1
            
            lines = response.split('\n')
            for line in lines:
                if 'UM98' in line:
                    parts = line.split(',')
                    if len(parts) > 5:
                        return {
                            'model': parts[3].strip('"'),
                            'firmware': parts[5].strip('"'),
                            'build_date': parts[7].strip('"') if len(parts) > 7 else 'Unknown'
                        }
        
        return None
    
    def set_rtcm_messages(self, messages: List[int], port: str = 'COM1', rate: float = 1.0) -> bool:
        """
        Configure RTCM3 message output
        
        Args:
            messages: List of RTCM message types
            port: Output port (COM1, COM2, COM3)
            rate: Output rate in seconds
            
        Returns:
            True if successful
        """
        if not self.serial or not self.serial.is_open:
            return False
        
        try:
            success_count = 0
            
            for msg_type in messages:
                if msg_type not in self.RTCM_MESSAGES:
                    logger.warning(f"Unsupported RTCM message: {msg_type}")
                    continue
                
                msg_name = self.RTCM_MESSAGES[msg_type]
                
                # Command format: RTCMMSG COM1 msg_name rate
                cmd = f'RTCMMSG {port} {msg_name} {rate}'
                response = self.send_command(cmd)
                
                if response and 'OK' in response:
                    logger.info(f"✓ Enabled {msg_name} on {port} at {rate}s")
                    success_count += 1
                else:
                    logger.error(f"Failed to enable {msg_name}: {response}")
            
            return success_count == len(messages)
            
        except Exception as e:
            logger.error(f"Set RTCM messages failed: {e}")
            return False
    
    def set_base_mode(self, mode: str, **kwargs) -> bool:
        """
        Configure base station mode
        
        Args:
            mode: 'auto' or 'fixed'
            **kwargs: Mode-specific parameters
                For auto: duration (seconds)
                For fixed: lat, lon, height
                
        Returns:
            True if successful
        """
        if not self.serial or not self.serial.is_open:
            return False
        
        try:
            if mode == 'auto':
                duration = kwargs.get('duration', 300)
                
                # Enable base mode with auto-survey
                cmd = f'MODE BASE TIME {duration}'
                response = self.send_command(cmd)
                
                if response and 'OK' in response:
                    logger.info(f"✓ Base mode: auto-survey {duration}s")
                    return True
                    
            elif mode == 'fixed':
                lat = kwargs.get('lat')
                lon = kwargs.get('lon')
                height = kwargs.get('height')
                
                if lat is None or lon is None or height is None:
                    logger.error("Fixed mode requires lat, lon, height")
                    return False
                
                # Set fixed base position
                # Format: MODE BASE lat lon height
                cmd = f'MODE BASE {lat} {lon} {height}'
                response = self.send_command(cmd)
                
                if response and 'OK' in response:
                    logger.info(f"✓ Base mode: fixed {lat}, {lon}, {height}")
                    return True
            else:
                logger.error(f"Unknown mode: {mode}")
                return False
            
            logger.error(f"Set base mode failed: {response}")
            return False
            
        except Exception as e:
            logger.error(f"Set base mode failed: {e}")
            return False
    
    def set_gnss_systems(self, systems: List[str]) -> bool:
        """
        Configure GNSS systems

        CAUTION - CONVENTION MISMATCH WITH set_signal_group_preset() BELOW:
        this method sends "CONFIG SIGNALGROUP {n}" treating n as a per-
        system OR-ed bitmask (system_bits below) - that bitmask semantics
        was NOT independently verified against Unicore's own command
        reference when this method was originally written. Per-turn
        investigation (this session) found CONFIG SIGNALGROUP is actually
        documented as a per-model PRESET INDEX, not a bitmask (UM982
        examples use two-argument forms like "CONFIG SIGNALGROUP 7 0",
        which a single OR-ed bitmask cannot express at all) - see
        set_signal_group_preset()'s docstring. Do not call both methods
        against the same receiver expecting them to compose; whichever is
        called last wins, and this method's bitmask values do not
        correspond to any documented preset. Left unchanged here rather
        than silently reinterpreted, since this method's own callers
        (config_manager.py profile format, gnss_config_feature.py's
        'gnss_systems' config key if used) may already depend on its
        existing (if unverified) argument shape.

        Args:
            systems: List of systems ('GPS', 'GLONASS', 'GALILEO', 'BEIDOU', 'QZSS')
        """
        # Convert to config command
        config_value = 0
        system_bits = {
            'GPS': 1,
            'GLONASS': 2,
            'GALILEO': 8,
            'BEIDOU': 4,
            'QZSS': 16
        }

        for system in systems:
            if system.upper() in system_bits:
                config_value |= system_bits[system.upper()]

        cmd = f'CONFIG SIGNALGROUP {config_value}'
        response = self.send_command(cmd)

        if response and 'OK' in response:
            logger.info(f"✓ GNSS systems: {', '.join(systems)}")
            return True
        else:
            logger.error(f"Failed to set GNSS systems: {response}")
            return False

    def set_signal_group_preset(self, preset: int = 2) -> bool:
        """
        Select a UM980/UM982 signal-group PRESET by index - NOT a bitmask
        (see the CAUTION note in set_gnss_systems() above; the two methods
        send the same underlying "CONFIG SIGNALGROUP" command with
        incompatible argument conventions - use one or the other for a
        given receiver, not both).

        Default preset=2 is asserted (Pesho, citing an official Unicore
        command reference plus ArduSimple documentation - not
        independently re-verified against either source directly in this
        session) to enable all available GNSS bands including Galileo E6,
        versus the receiver's factory-default preset 1 which excludes
        some bands. This is independently corroborated by two facts this
        session DID verify directly: (1) GNSSOEM/ELT_RTKBase's
        Install/UM980_RTCM3_OUT.txt - a field config for UM980 base
        stations - uses "CONFIG SIGNALGROUP 2"; (2) this project's own
        pre-existing receiver_cfg/Unicore_UM980_rtcm3.cfg (predates any
        ELT_RTKBase involvement) already uses the identical value. Two
        independent sources landing on the same non-default preset is
        reasonable grounds to adopt it, even without this session
        directly inspecting the underlying manual.

        NOTE: per UM982_RTCM3_OUT.txt/UM982_HAS.txt in the same
        ELT_RTKBase source, UM982 uses a two-argument form ("CONFIG
        SIGNALGROUP 7 0" / "3 6") not covered by this single-int method -
        this method is scoped to the UM980's confirmed single-argument
        form only. Do not assume preset=2 carries the same meaning on a
        UM982 without separately confirming its own preset table.

        Sends "CONFIG SIGNALGROUP {n}" as a single-argument command
        (matching UM980_RTCM3_OUT.txt's syntax exactly) - reconnect/reset
        may be required afterward, since this project's own
        receiver_cfg/Unicore_UM980_rtcm3.cfg carries the comment
        "SIGNALGROUP will reset the device".

        :param preset: signal-group preset index (UM980 single-argument
            form only)
        """
        cmd = f'CONFIG SIGNALGROUP {preset}'
        response = self.send_command(cmd)

        if response and 'OK' in response:
            logger.info(f"✓ Signal group preset: {preset}")
            return True
        else:
            logger.error(f"Failed to set signal group preset: {response}")
            return False

    def set_elevation_mask(self, angle: int = 10) -> bool:
        """Set elevation mask angle (degrees)"""
        cmd = f'ECUTOFF {angle}'
        response = self.send_command(cmd)

        if response and 'OK' in response:
            logger.info(f"✓ Elevation mask: {angle}°")
            return True
        return False

    def set_undulation(self, undulation_m: float = 0) -> bool:
        """
        Set the geoid undulation value (meters) the receiver applies
        internally to its own height output.

        Cherry-picked from GNSSOEM/ELT_RTKBase's Install/UM980_RTCM3_OUT.txt
        ("CONFIG UNDULATION 0") - a field-tested UM980 base-station RTCM3
        config, not this project's own prior work. Default 0 disables the
        receiver's own undulation correction, leaving height handling
        entirely to this pipeline's own geoid_corrector.py /
        bgs2005_transformer.py (see survey_controller.py's Step 6/8) -
        avoids the receiver silently double-correcting height underneath
        this project's own height pipeline.
        """
        cmd = f'CONFIG UNDULATION {undulation_m}'
        response = self.send_command(cmd)

        if response and 'OK' in response:
            logger.info(f"✓ Undulation: {undulation_m}m")
            return True
        return False

    def set_base_antenna_model(self, model: str = "ELT0123", radome: str = "",
                                height_offset: float = 0, height_type: str = "USER") -> bool:
        """
        Set the base station antenna model info the receiver embeds in its
        own RTCM output (independent of this pipeline's own ANTEX handling
        in ppp_processor.py, which already uses ant1-anttype=NONE for
        PPP-static processing - see that file's module docstring).

        Cherry-picked from GNSSOEM/ELT_RTKBase's Install/UM980_RTCM3_OUT.txt
        ("CONFIG BASEANTENNAMODEL \"ELT0123\" \"\" 0 USER"). "ELT0123" is
        THEIR antenna model identifier, not verified as meaningful for this
        station's actual (uncalibrated K700) antenna - kept as the
        cherry-picked default's own value since the exact string does not
        need to match a real IGS ANTEX entry for this command to apply
        (same reasoning as ant1-anttype=NONE elsewhere in this project:
        the antenna is uncalibrated, so no calibrated model name is
        "more correct" than any other placeholder here). Confirm/override
        via config if this default proves wrong for a specific station.

        :param model: antenna model identifier string
        :param radome: radome identifier string (empty = none)
        :param height_offset: antenna height offset (meters)
        :param height_type: height reference type, per UM980 command set
        """
        cmd = f'CONFIG BASEANTENNAMODEL "{model}" "{radome}" {height_offset} {height_type}'
        response = self.send_command(cmd)

        if response and 'OK' in response:
            logger.info(f"✓ Base antenna model: {model!r}")
            return True
        return False

    def set_rtcm_snr_mask(self, gps_min_cn0: int = 32, glonass_min_cn0: int = 36) -> bool:
        """
        Configure the SNR-based (C/N0) mask applied to satellites before
        they're included in RTCM output - a coarser, signal-quality-driven
        filter distinct from set_elevation_mask()'s pure geometric cutoff.

        Cherry-picked from GNSSOEM/ELT_RTKBase's Install/UM980_RTCM3_OUT.txt
        ("MASK RTCMCN0 32" / "MASK RTCMCN0 36 GLO") - exact syntax
        confirmed against that file, not guessed: a bare "MASK RTCMCN0 <n>"
        sets the default/GPS threshold, and a second call with a
        constellation suffix (here "GLO") overrides it per-constellation.
        This project's own receiver_cfg/Unicore_UM980_rtcm3.cfg predates
        this and has no equivalent mask - this is a new addition, not a
        replacement of an existing project convention.

        :param gps_min_cn0: minimum C/N0 (dBHz) for GPS/default satellites
        :param glonass_min_cn0: minimum C/N0 (dBHz) for GLONASS satellites
        """
        success = True

        response = self.send_command(f'MASK RTCMCN0 {gps_min_cn0}')
        if response and 'OK' in response:
            logger.info(f"✓ RTCM SNR mask (default/GPS): {gps_min_cn0} dBHz")
        else:
            logger.error(f"Failed to set default RTCM SNR mask: {response}")
            success = False

        response = self.send_command(f'MASK RTCMCN0 {glonass_min_cn0} GLO')
        if response and 'OK' in response:
            logger.info(f"✓ RTCM SNR mask (GLONASS): {glonass_min_cn0} dBHz")
        else:
            logger.error(f"Failed to set GLONASS RTCM SNR mask: {response}")
            success = False

        return success

    def set_sbas_enabled(self, enabled: bool = False) -> bool:
        """
        Enable or disable SBAS tracking/use.

        Cherry-picked from GNSSOEM/ELT_RTKBase's Install/UM980_RTCM3_OUT.txt
        ("CONFIG SBAS DISABLE"). NOTE: this project's own, pre-existing
        receiver_cfg/Unicore_UM980_rtcm3.cfg instead uses
        "CONFIG SBAS ENABLE AUTO" - the opposite default. This method does
        not silently override that file; it's a new, explicit knob a
        caller opts into (default parameter value matches ELT_RTKBase's
        DISABLE choice since SBAS corrections are irrelevant for a static
        base station transmitting its own precisely-surveyed position, but
        the pre-existing .cfg's ENABLE AUTO default is left untouched
        elsewhere in this codebase).

        :param enabled: True to enable SBAS, False to disable
        """
        cmd = 'CONFIG SBAS ENABLE AUTO' if enabled else 'CONFIG SBAS DISABLE'
        response = self.send_command(cmd)

        if response and 'OK' in response:
            logger.info(f"✓ SBAS: {'enabled (auto)' if enabled else 'disabled'}")
            return True
        return False

    def set_rtcm_clock_offset(self, enabled: bool = False) -> bool:
        """
        Enable or disable inclusion of the receiver clock offset in RTCM
        output.

        Cherry-picked from GNSSOEM/ELT_RTKBase's Install/UM980_RTCM3_OUT.txt
        ("CONFIG RTCMCLOCKOFFSET DISABLE"). Default False (disabled)
        matches that cherry-picked default - not independently verified
        against this project's own PPP-static pipeline behavior; if a live
        station shows unexpected RTCM clock-related artifacts after
        enabling this, that's the first setting to reconsider.

        :param enabled: True to enable clock offset in RTCM output, False
            to disable
        """
        cmd = 'CONFIG RTCMCLOCKOFFSET ENABLE' if enabled else 'CONFIG RTCMCLOCKOFFSET DISABLE'
        response = self.send_command(cmd)

        if response and 'OK' in response:
            logger.info(f"✓ RTCM clock offset: {'enabled' if enabled else 'disabled'}")
            return True
        return False

    def save_config(self) -> bool:
        """Save configuration to flash"""
        response = self.send_command('SAVECONFIG')
        
        if response and 'OK' in response:
            logger.info("✓ Configuration saved to flash")
            return True
        else:
            logger.error(f"Save config failed: {response}")
            return False
    
    def reset_receiver(self, reset_type: str = 'hot') -> bool:
        """
        Reset receiver
        
        Args:
            reset_type: 'hot', 'warm', 'cold'
        """
        reset_commands = {
            'hot': 'RESET HOTRESET',
            'warm': 'RESET WARMRESET',
            'cold': 'RESET COLDRESET'
        }
        
        cmd = reset_commands.get(reset_type)
        if not cmd:
            logger.error(f"Unknown reset type: {reset_type}")
            return False
        
        try:
            self.send_command(cmd, wait_for_ok=False)
            logger.info(f"✓ Receiver reset ({reset_type})")
            return True
        except Exception as e:
            logger.error(f"Reset failed: {e}")
            return False
    
    def get_current_config(self) -> Dict:
        """Get current receiver configuration"""
        config = {}
        
        # Get position mode
        response = self.send_command('MODE')
        if response:
            config['mode'] = response
        
        # Get RTCM messages
        response = self.send_command('RTCMMSG')
        if response:
            config['rtcm_messages'] = response
        
        # Get GNSS systems
        response = self.send_command('CONFIG SIGNALGROUP')
        if response:
            config['gnss_systems'] = response
        
        return config
