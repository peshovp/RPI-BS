"""
Watchdog Feature - System Health Monitoring and Auto-Recovery
==============================================================

Modular monitoring system with configurable components:
- Service Monitor: RTKBase services health
- Network Monitor: Internet & VPN connectivity
- Disk Monitor: Storage space alerts
- GNSS Monitor: Receiver connectivity

All monitors can be enabled/disabled independently via web UI.
"""

from .watchdog_controller import WatchdogController

__all__ = ['WatchdogController']
