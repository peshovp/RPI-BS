"""Shared helpers for detecting and performing a verified systemd daemon-reload.
Callers must run as root. NeedDaemonReload=yes means the unit file on disk
is not the definition systemd has loaded."""

import subprocess
from typing import List, Dict, Any

MANAGED_PREFIXES = ("str2str_", "rtkbase_", "geomaxima_")
MANAGED_SUFFIXES = (".service", ".timer")


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
