"""
WireGuard Settings Parser/Writer
=================================

Reads and writes /etc/wireguard/wg0.conf in the same *positional list* format
used by RTKBaseConfigManager.get_*_settings() methods, so the WireGuard
section in settings.html/settings.js can be handled exactly like the native
RTKBase sections (Socket.IO "form data" save flow).

This is kept as a separate module (not a method on RTKBaseConfigManager)
because wg0.conf is NOT part of settings.conf: it's a different file, in a
different location (/etc/wireguard/), with a different INI-like dialect
(WireGuard's own [Interface]/[Peer] format, case-sensitive keys). Mixing its
parsing logic into RTKBaseConfigManager (whose whole purpose is settings.conf)
would blur the single responsibility of that class. A standalone module keeps
the RTKBase config manager untouched and makes the WireGuard glue code easy to
find/remove later if the feature is dropped or reworked.
"""

import os
import shutil
import logging
from configparser import ConfigParser

logger = logging.getLogger(__name__)

WG_CONFIG_DIR = "/etc/wireguard"
WG_INTERFACE = "wg0"
WG_CONFIG_FILE = os.path.join(WG_CONFIG_DIR, f"{WG_INTERFACE}.conf")

# Ordered list of (source_key, section, option) mirroring the
# [{"source_section": ...}, {key: val}, ...] convention from
# RTKBaseConfigManager.get_file_settings() and friends.
_FIELD_MAP = (
    ("private_key", "Interface", "PrivateKey"),
    ("address", "Interface", "Address"),
    ("dns", "Interface", "DNS"),
    ("peer_public_key", "Peer", "PublicKey"),
    ("endpoint", "Peer", "Endpoint"),
    ("allowed_ips", "Peer", "AllowedIPs"),
    ("persistent_keepalive", "Peer", "PersistentKeepalive"),
)


def get_wireguard_settings(config_file=WG_CONFIG_FILE):
    """
        Parse /etc/wireguard/wg0.conf into the RTKBase positional list format:
        [{"source_section": "wireguard"}, {"private_key": ...}, {"address": ...},
         {"dns": ...}, {"peer_public_key": ...}, {"endpoint": ...},
         {"allowed_ips": ...}, {"persistent_keepalive": ...}]

        If the file doesn't exist or can't be parsed, returns the same
        structure with empty string defaults instead of raising, so the
        settings page can still render.

        :param config_file: path to the wg0.conf file (overridable for tests)
        :return: ordered list, same convention as RTKBaseConfigManager.get_*_settings()
    """
    ordered_wireguard = [{"source_section": "wireguard"}]

    values = {key: "" for key, _section, _option in _FIELD_MAP}

    if os.path.exists(config_file):
        try:
            parser = ConfigParser(interpolation=None, strict=False)
            # Preserve case: WireGuard keys are case-sensitive (PrivateKey, not privatekey)
            parser.optionxform = str
            parser.read(config_file)

            for key, section, option in _FIELD_MAP:
                if parser.has_section(section) and parser.has_option(section, option):
                    values[key] = parser.get(section, option).strip()
        except Exception as e:
            logger.error(f"Failed to parse {config_file}: {e}")
            # keep defaults (empty strings) on parse failure

    for key, _section, _option in _FIELD_MAP:
        ordered_wireguard.append({key: values[key]})

    return ordered_wireguard


def write_wireguard_config(fields_dict, config_file=WG_CONFIG_FILE):
    """
        Reconstruct a valid wg0.conf from a dict of field values and write it
        to disk. Creates a ".backup" copy of the previous file first (same
        convention already used by addons/features/wireguard_client.py), then
        writes the new file with 0600 permissions (private key material).

        :param fields_dict: dict with keys matching _FIELD_MAP source keys
            (private_key, address, dns, peer_public_key, endpoint,
            allowed_ips, persistent_keepalive)
        :param config_file: path to the wg0.conf file (overridable for tests)
        :return: True on success, False on failure
    """
    try:
        config_dir = os.path.dirname(config_file)
        os.makedirs(config_dir, mode=0o700, exist_ok=True)

        # Backup existing config before overwriting
        if os.path.exists(config_file):
            backup_file = f"{config_file}.backup"
            shutil.copy2(config_file, backup_file)

        parser = ConfigParser(interpolation=None, strict=False)
        parser.optionxform = str
        parser.add_section("Interface")
        parser.add_section("Peer")

        for key, section, option in _FIELD_MAP:
            value = fields_dict.get(key, "")
            if value:
                parser.set(section, option, value)

        with open(config_file, "w") as configfile:
            parser.write(configfile, space_around_delimiters=True)

        os.chmod(config_file, 0o600)

        logger.info(f"WireGuard configuration written to {config_file}")
        return True

    except Exception as e:
        logger.error(f"Failed to write {config_file}: {e}")
        return False
