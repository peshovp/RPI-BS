"""
Shared settings.conf path-resolution helper.

GeoMaxima - 2026-10-05 archive incident fix: gnss_monitor.py's raw-data-
freshness check needs to resolve settings.conf's [local_storage]
datadir (which may contain the literal, unexpanded "$BASEDIR"
placeholder settings.conf.default ships) - the SAME substitution
web_app/RTKBaseConfigManager.py's own expand_path() already performs on
an in-memory, already-parsed ConfigParser value. gnss_monitor.py's first
draft resolved this with a guessed ".parent" chain counted up from its
own file location instead - exactly the kind of silent-failure-prone
guess this incident investigation is about removing. This module
implements the SAME algorithm (read [local_storage] datadir, replace a
literal "$BASEDIR" with the settings.conf file's own parent directory),
independently of RTKBaseConfigManager (which reads from an already-
parsed ConfigParser, not from a file path, so it is NOT changed to call
this - re-plumbing its existing, tested, in-production expand_path()
was judged too risky to do as a side effect of an incident-response fix;
this is intentionally a second, verified-identical implementation of
the same resolution, not a shared call into the first). Verified
producing identical output for the real-world settings.conf.default
format in this session's own testing.
"""

import configparser
from pathlib import Path
from typing import Optional


def resolve_datadir(settings_conf_path: Path) -> Optional[Path]:
    """
    Read [local_storage] datadir from the given settings.conf path and
    expand a literal "$BASEDIR" placeholder to settings_conf_path's own
    parent directory (the rtkbase root) - the exact substitution
    RTKBaseConfigManager.expand_path() performs.

    :param settings_conf_path: path to a settings.conf file (not
        settings.conf.default - this reads the live, merged file)
    :return: resolved Path, or None if the file doesn't exist, the key
        is missing/empty, or the file can't be parsed. Never raises -
        callers must treat None as "could not resolve", not assume a
        default.
    """
    if not settings_conf_path.exists():
        return None
    try:
        parser = configparser.ConfigParser(interpolation=None)
        parser.read(settings_conf_path)
        datadir = parser.get("local_storage", "datadir", fallback="").strip("'\"")
    except configparser.Error:
        return None
    if not datadir:
        return None
    if "$BASEDIR" in datadir:
        basedir = str(settings_conf_path.parent)
        datadir = datadir.replace("$BASEDIR", basedir)
    return Path(datadir)
