"""
NASA Earthdata Login Credentials for PPP-static Precise Products
==================================================================

Reads and writes the [earthdata] section of settings.conf, storing the
NASA Earthdata Login username/password used by
addons/features/auto_survey/ppp_downloader.py to authenticate against
CDDIS for SP3/CLK precise-product downloads.

Follows the exact same secret-field-preservation convention already
established for WireGuard (web_app/wireguard_settings.py): the password
field is never re-populated with the real stored value in the Settings
page HTML, so a blank submission means "leave unchanged", not "clear it".
This module exists specifically to avoid regressing that lesson - an
earlier, unrelated bug wiped WireGuard's PrivateKey on every blank-field
save before that convention was established.

Stored directly in RTKBase's own settings.conf (per Pesho's explicit
decision), not a separate credentials file - this differs from WireGuard's
storage location (a separate wg0.conf) because earthdata credentials have
no equivalent "system file" of their own to live in.
"""

import os
import logging
from configparser import ConfigParser

logger = logging.getLogger(__name__)

EARTHDATA_SECTION = "earthdata"

# Mirrors wireguard_settings.py's _FIELD_MAP convention.
_FIELD_MAP = (
    ("username", EARTHDATA_SECTION, "username"),
    ("password", EARTHDATA_SECTION, "password"),
)

_SECRET_KEYS = ("password",)


def _default_settings_file():
    # Resolve rtkbase root the same way rtkbase_config.py/survey_controller.py
    # do: relative to this file's location, not $HOME (may run as root via
    # systemd).
    _rtkbase_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    return os.path.join(_rtkbase_root, "settings.conf")


def get_earthdata_settings(settings_file=None):
    """
    Parse the [earthdata] section of settings.conf into the RTKBase
    positional list format used throughout settings.html:
    [{"source_section": "earthdata"}, {"username": ...}, {"password": ...}]

    If the section or file doesn't exist, returns the same structure with
    empty string defaults instead of raising, so the settings page can
    still render.

    :param settings_file: path to settings.conf (overridable for tests)
    :return: ordered list, same convention as get_wireguard_settings()
    """
    if settings_file is None:
        settings_file = _default_settings_file()

    ordered = [{"source_section": EARTHDATA_SECTION}]
    values = {key: "" for key, _section, _option in _FIELD_MAP}

    if os.path.exists(settings_file):
        try:
            parser = ConfigParser(interpolation=None, strict=False)
            parser.read(settings_file)

            for key, section, option in _FIELD_MAP:
                if parser.has_section(section) and parser.has_option(section, option):
                    values[key] = parser.get(section, option).strip().strip("'\"")
        except Exception as e:
            logger.error(f"Failed to parse [{EARTHDATA_SECTION}] from {settings_file}: {e}")
            # keep defaults (empty strings) on parse failure

    for key, _section, _option in _FIELD_MAP:
        ordered.append({key: values[key]})

    return ordered


def has_earthdata_credentials(settings_file=None) -> bool:
    """Convenience check for ppp_downloader.py: are both fields non-empty?"""
    settings = get_earthdata_settings(settings_file)
    values = {}
    for item in settings[1:]:
        values.update(item)
    return bool(values.get("username")) and bool(values.get("password"))


def write_earthdata_settings(fields_dict, settings_file=None) -> bool:
    """
    Write the [earthdata] section into settings.conf, preserving the rest
    of the file untouched.

    SECRET FIELD PRESERVATION: password is never re-populated in the
    Settings form HTML (see settings.html). An empty incoming value means
    "user did not intend to change this" rather than "clear it" - the
    existing on-disk value is preserved in that case, exactly as
    write_wireguard_config() already does for private_key/preshared_key.

    :param fields_dict: dict with keys "username", "password"
    :param settings_file: path to settings.conf (overridable for tests)
    :return: True on success, False on failure
    """
    if settings_file is None:
        settings_file = _default_settings_file()

    try:
        existing_values = {}
        if os.path.exists(settings_file):
            try:
                existing = get_earthdata_settings(settings_file)
                for item in existing[1:]:
                    existing_values.update(item)
            except Exception as e:
                logger.warning(f"Could not read existing [{EARTHDATA_SECTION}] for secret-field merge: {e}")

        parser = ConfigParser(interpolation=None, strict=False)
        if os.path.exists(settings_file):
            parser.read(settings_file)

        if not parser.has_section(EARTHDATA_SECTION):
            parser.add_section(EARTHDATA_SECTION)

        for key, section, option in _FIELD_MAP:
            value = fields_dict.get(key, "")
            if not value and key in _SECRET_KEYS:
                value = existing_values.get(key, "")
            parser.set(section, option, f"'{value}'")

        tmp_path = f"{settings_file}.tmp"
        with open(tmp_path, "w") as f:
            parser.write(f, space_around_delimiters=False)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, settings_file)

        # NOTE: settings.conf is shared with several other writers
        # (RTKBaseConfigManager, rtkbase_config.py's update_position(), the
        # NTRIP/local-caster password fields already stored here in
        # plaintext) and none of them chmod it - intentionally not adding a
        # chmod here either, to avoid unilaterally changing permissions a
        # non-root service (e.g. run_cast.sh sourcing this file) may depend
        # on. If tighter permissions are wanted, that's a repo-wide decision
        # for install.sh, not something this one write path should impose.
        logger.info(f"Earthdata Login credentials written to {settings_file}")
        return True

    except Exception as e:
        logger.error(f"Failed to write [{EARTHDATA_SECTION}] to {settings_file}: {e}")
        return False
