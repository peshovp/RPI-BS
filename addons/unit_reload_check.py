"""Shared helpers for detecting and performing a verified systemd daemon-reload.
Callers must run as root. NeedDaemonReload=yes means the unit file on disk
is not the definition systemd has loaded."""

import subprocess
from typing import List, Dict, Any

MANAGED_PREFIXES = ("str2str_", "rtkbase_", "geomaxima_")
MANAGED_SUFFIXES = (".service", ".timer")

# The web app is restarted by the OTA itself as its last step; str2str_file is
# survey-only and must never be restarted from here.
DO_NOT_RESTART = frozenset({"rtkbase_web.service", "str2str_file.service"})


def list_managed_units() -> List[str]:
    try:
        r = subprocess.run(
            ["systemctl", "list-unit-files", "--no-legend"],
            capture_output=True, text=True, timeout=15
        )
        units = []
        for line in r.stdout.splitlines():
            parts = line.split()
            if not parts:
                continue
            name = parts[0]
            if "@" in name:
                continue
            if not any(name.endswith(s) for s in MANAGED_SUFFIXES):
                continue
            if any(name.startswith(p) for p in MANAGED_PREFIXES):
                units.append(name)
        return sorted(set(units))
    except Exception:
        return []


def units_needing_reload() -> List[str]:
    try:
        result = []
        for unit in list_managed_units():
            try:
                r = subprocess.run(
                    ["systemctl", "show", "-p", "NeedDaemonReload", "--value", unit],
                    capture_output=True, text=True, timeout=10
                )
                if r.stdout.strip() == "yes":
                    result.append(unit)
            except Exception:
                pass
        return sorted(result)
    except Exception:
        return []


def reload_if_needed() -> Dict[str, Any]:
    before = units_needing_reload()
    if not before:
        return {"reloaded": False, "units": [], "returncode": None, "still_needing_reload": []}
    try:
        r = subprocess.run(
            ["systemctl", "daemon-reload"],
            capture_output=True, text=True, timeout=60
        )
        rc = r.returncode
    except Exception:
        rc = -1
    after = units_needing_reload()
    return {"reloaded": True, "units": before, "returncode": rc, "still_needing_reload": after}


def reload_and_restart_changed() -> Dict[str, Any]:
    result = reload_if_needed()
    result = dict(result)
    result["restarted"] = []
    result["restart_failed"] = []

    if not result["reloaded"] or result["returncode"] != 0 or result["still_needing_reload"]:
        return result

    for unit in result["units"]:
        if unit in DO_NOT_RESTART:
            continue
        try:
            r = subprocess.run(
                ["systemctl", "is-active", "--quiet", unit],
                capture_output=True, text=True, timeout=10
            )
            if r.returncode != 0:
                continue
            r = subprocess.run(
                ["systemctl", "restart", unit],
                capture_output=True, text=True, timeout=60
            )
            if r.returncode == 0:
                result["restarted"].append(unit)
            else:
                result["restart_failed"].append(unit)
        except Exception:
            result["restart_failed"].append(unit)

    return result
