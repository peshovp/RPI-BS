"""
addons/platform_info.py

Python equivalent of tools/platform_detect.sh, for the Flask web app / OTA
Python code that needs to know what board and OS it's running on (e.g.
gating raspi-config-only features, excluding serial console ports from
GNSS auto-detection).

Pure, side-effect-free: reading /etc/armbian-release, /proc/cmdline, and
device-tree files never mutates anything, and every read is wrapped so a
missing/unreadable file degrades to "unknown" rather than raising.

A733/sun60iw2 (Orange Pi 4 Pro+ and any future board on the same SoC
family) is matched by LINUXFAMILY/kernel release string, not by exact
board name, so this stays correct for future boards without a code change.
"""
from __future__ import annotations

import os
import re
from dataclasses import dataclass
from functools import lru_cache

DEVICETREE_MODEL_PATH = "/sys/firmware/devicetree/base/model"
ARMBIAN_RELEASE_PATH = "/etc/armbian-release"
PROC_CMDLINE_PATH = "/proc/cmdline"
CONSOLE_ACTIVE_PATH = "/sys/class/tty/console/active"


@dataclass(frozen=True)
class PlatformInfo:
    platform: str  # "rpi" | "armbian-a733" | "armbian" | "unknown"
    board: str
    arch: str
    console_ttys: frozenset


def _read_text(path: str) -> str:
    try:
        with open(path, "r", errors="ignore") as fh:
            return fh.read()
    except OSError:
        return ""


def _read_devicetree_model() -> str:
    try:
        with open(DEVICETREE_MODEL_PATH, "rb") as fh:
            return fh.read().decode(errors="ignore").strip("\x00").strip()
    except OSError:
        return ""


def _parse_armbian_release() -> dict:
    """Parse /etc/armbian-release's KEY=VALUE lines without executing it."""
    fields: dict = {}
    for line in _read_text(ARMBIAN_RELEASE_PATH).splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        fields[key.strip()] = value.strip().strip('"')
    return fields


def _detect_console_ttys() -> frozenset:
    ttys = set()
    for match in re.findall(r"console=(tty[A-Za-z0-9]*)", _read_text(PROC_CMDLINE_PATH)):
        ttys.add(match)
    for tok in _read_text(CONSOLE_ACTIVE_PATH).split():
        if tok.startswith("tty"):
            ttys.add(tok)
    return frozenset(ttys)


@lru_cache(maxsize=1)
def detect_platform() -> PlatformInfo:
    """Detect the current board/platform. Cached - the answer cannot change
    at runtime without a reboot, and this is called from request handlers."""
    arch = os.uname().machine
    board = _read_devicetree_model()

    if "Raspberry Pi" in board:
        return PlatformInfo("rpi", board, arch, _detect_console_ttys())

    armbian_fields = _parse_armbian_release()
    if armbian_fields:
        board = armbian_fields.get("BOARD") or board
        family = armbian_fields.get("LINUXFAMILY", "")
        kernel_release = os.uname().release
        if "sun60iw2" in family or "sun60iw2" in kernel_release:
            platform = "armbian-a733"
        else:
            platform = "armbian"
        return PlatformInfo(platform, board, arch, _detect_console_ttys())

    return PlatformInfo("unknown", board, arch, _detect_console_ttys())


def is_raspberry_pi() -> bool:
    return detect_platform().platform == "rpi"


def is_armbian() -> bool:
    return detect_platform().platform.startswith("armbian")
