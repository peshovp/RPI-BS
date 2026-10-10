import os
from pystemd.systemd1 import Unit
from pystemd.systemd1 import Manager

class ServiceController(object):
    """
        A simple wrapper around pystemd to manage systemd services
    """
    
    manager = Manager(_autoload=True)

    def __init__(self, unit):
        """
            param: unit: a systemd unit name (ie str2str_tcp.service...)
        """
        self.unit = Unit(bytes(unit, 'utf-8'), _autoload=True)
        
    def isActive(self):
        if self.unit.Unit.ActiveState == b'active':
            return True
        elif self.unit.Unit.ActiveState == b'activating':
            #TODO manage this transitionnal state differently
            return True
        else:
            return False

    def isEnabled(self):
        """
            GeoMaxima - 2026-10-10: True if the unit is persistently
            enabled (UnitFileState == 'enabled') - the same signal
            _file_logging_enabled_by_user() (survey_controller.py) and
            ServiceMonitor._check_service() (watchdog) already use via
            `systemctl is-enabled`, exposed here on ServiceController so
            a Flask route/template can read it without a second,
            separate subprocess call.
        """
        return self.unit.Unit.UnitFileState == b'enabled'

    def get_nrestart(self):
        """
            Get the number of restarts since the last service startup
        """
        return self.unit.Service.NRestarts

    def get_result(self):
        """
            Get the unit return status.
            success => it's ok
            exit-code => str2str doesn't start successfully
            We can read a success between the startup and the first error
        """
        if "org.freedesktop.systemd1.Service" in self.unit._interfaces:
            return self.unit.Service.Result.decode()
        elif "org.freedesktop.systemd1.Timer" in self.unit._interfaces:
            return self.unit.Timer.Result.decode()

    def getUser(self):
        return self.unit.Service.User.decode()
    
    def status(self):
        """
            get the unit status:
            auto-restart: the service will restart later
            start: the service is starting
            running; the service is running
        """
        return (self.unit.Unit.SubState).decode()

    def start(self):
        """
            Start the unit.
            It will reset the failed counter before starting the unit.
        """
        try:
            self.manager.Manager.ResetFailedUnit(self.unit.Unit.Names[0])
        except:
            pass
        self.manager.Manager.EnableUnitFiles(self.unit.Unit.Names, False, True)
        return self.unit.Unit.Start(b'replace')
        
    def stop(self):
        """
            Stop the unit.

            INTENTIONALLY disables the unit as well as stopping it - this
            is the semantics the UI's own on/off toggle
            (web_app/server.py's switchService()) relies on: switching a
            service "off" in Settings must survive a reboot, not just
            pause until the next restart. Do NOT change this method's
            semantics - use stop_temporarily() below for any TEMPORARY
            stop (anything that intends to start the unit again itself,
            shortly after, as part of the same operation).
        """
        self.manager.Manager.DisableUnitFiles(self.unit.Unit.Names, False)
        return self.unit.Unit.Stop(b'replace')

    def stop_temporarily(self):
        """
            Stop the unit WITHOUT disabling it - for any TEMPORARY stop
            (the caller intends to start it again itself, as part of the
            same operation, not leave it off).

            GeoMaxima - 2026-10-07 review fix: stop() above disables as
            well as stops (upstream's own intentional semantics for the
            UI's on/off toggle - confirmed via web_app/server.py's
            switchService(), which must disable on a user-initiated
            "off"). Before this method existed, EVERY temporary-stop
            caller that reused stop() for convenience (e.g.
            web_app/server.py's configure_receiver(), which stops the
            main service only to reconfigure a GNSS receiver and
            restarts it moments later) was disabling the unit as a side
            effect - self-healing only because that specific caller
            happens to always call start() again afterward (which
            re-enables), but leaving the unit disabled if that later
            start() is ever skipped (an early return, an exception, a
            crash). Any future temporary-stop caller must use THIS
            method, not stop().
        """
        return self.unit.Unit.Stop(b'replace')

    def restart(self):
        """
            Restart the unit.
        """
        return self.unit.Unit.Restart(b'replace')