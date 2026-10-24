"""Autosurvey runner: runs the GNSS survey outside the web server process.

The survey used to run in a thread inside the web server process, where it was
killed by gunicorn worker timeouts and by web restarts. It now runs in its own
systemd service (geomaxima_survey.service), started as:

    python -m addons.features.auto_survey.survey_runner

The web app submits requests (start / stop / reset) through the survey_requests
module. The runner creates the survey controller, lets it RECONCILE (resume a
survey that was interrupted by a crash, reboot or restart), then serves
requests. If the receiver is not yet ready, the survey stays 'running' and the
loop retries recovery periodically. The persisted survey state is never stopped
or modified on shutdown, so the survey resumes on the next start.

The runner also hosts the CORS position job, handling cors_compute, cors_cancel
and cors_apply requests from the web app.
"""

import logging
import os
import signal
import sys
import threading
import time

try:
    from . import survey_requests
except ImportError:  # loaded standalone (tests): load the sibling module by path
    import importlib.util as _ilu
    _sr_spec = _ilu.spec_from_file_location(
        "survey_requests",
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "survey_requests.py"))
    survey_requests = _ilu.module_from_spec(_sr_spec)
    _sr_spec.loader.exec_module(survey_requests)

logger = logging.getLogger("autosurvey.runner")


class SurveyRunner:
    """Polls the request directory and drives the survey controller."""

    def __init__(self, controller_factory, request_dir=None,
                 poll_interval=1.0, status_interval=30.0, cleanup_interval=600.0,
                 recover_retry_interval=30.0, cors_manager_factory=None):
        self.controller_factory = controller_factory
        self.request_dir = request_dir or survey_requests.DEFAULT_REQUEST_DIR
        self.poll_interval = poll_interval
        self.status_interval = status_interval
        self.cleanup_interval = cleanup_interval
        self.recover_retry_interval = recover_retry_interval
        self.cors_manager_factory = cors_manager_factory
        self.cors = None
        self.controller = None

    def startup(self):
        """Create the controller and reconcile any interrupted survey."""
        self.controller = self.controller_factory()
        self.controller.is_runner = True

        # Create CORS job manager if factory provided
        if self.cors_manager_factory is not None:
            try:
                self.cors = self.cors_manager_factory(self.controller)
            except Exception:
                logger.exception("CORS job manager unavailable")
                self.cors = None

        try:
            resumed = self.controller.recover_survey()
        except Exception:
            logger.exception("reconcile failed")
            resumed = False
        if resumed:
            logger.info("reconcile: resumed an interrupted survey")
        else:
            logger.info("reconcile: nothing to resume")
        return resumed

    def handle_request(self, request):
        """Handle a single survey request. Returns {'ok': bool, 'message': str, 'data': None}."""
        action = request.get("action")
        params = request.get("params") or {}
        try:
            if action == "start":
                target_hours = params.get("target_hours", 24)
                if isinstance(target_hours, bool) or not isinstance(target_hours, int):
                    return {"ok": False, "message": "target_hours must be an integer", "data": None}
                if not (1 <= target_hours <= 168):
                    return {"ok": False, "message": "target_hours must be between 1 and 168", "data": None}

                started = self.controller.start_survey(target_hours=target_hours)
                if started:
                    return {"ok": True, "message": "started", "data": None}
                return {"ok": False, "message": "survey could not be started (already running?)", "data": None}

            elif action == "stop":
                stopped = self.controller.stop_survey()
                if stopped:
                    return {"ok": True, "message": "stopped", "data": None}
                return {"ok": True, "message": "nothing was running", "data": None}

            elif action == "reset":
                self.controller.reset_survey()
                return {"ok": True, "message": "reset", "data": None}

            elif action == "cors_compute":
                account_id = params.get("account_id")
                if not isinstance(account_id, str):
                    return {"ok": False, "message": "account_id must be a string", "data": None}
                if self.cors is None:
                    return {"ok": False, "message": "CORS feature unavailable", "data": None}
                ok, msg = self.cors.start(account_id)
                if ok:
                    return {"ok": True, "message": "started", "data": {"job_id": msg}}
                return {"ok": False, "message": msg, "data": None}

            elif action == "cors_cancel":
                if self.cors is None:
                    return {"ok": False, "message": "CORS feature unavailable", "data": None}
                cancelled = self.cors.cancel()
                if cancelled:
                    return {"ok": True, "message": "cancel requested", "data": None}
                return {"ok": True, "message": "nothing was running", "data": None}

            elif action == "cors_apply":
                job_id = params.get("job_id")
                if not isinstance(job_id, str):
                    return {"ok": False, "message": "job_id must be a string", "data": None}
                confirmed = params.get("confirmed") is True
                force = params.get("force") is True
                if self.cors is None:
                    return {"ok": False, "message": "CORS feature unavailable", "data": None}
                res = self.cors.apply(job_id, confirmed, force)
                if res["ok"]:
                    return {"ok": True, "message": "applied", "data": res.get("apply_result")}
                return {"ok": False, "message": res["reason"] or "apply failed", "data": res.get("apply_result")}

            else:
                return {"ok": False, "message": f"unknown action: {action}", "data": None}

        except Exception as e:
            logger.exception("error handling request %s", action)
            return {"ok": False, "message": f"{type(e).__name__}: {e}", "data": None}

    def run_once(self):
        """Take and handle one request. Returns True if a request was handled."""
        request = survey_requests.take_next_request(request_dir=self.request_dir)
        if request is None:
            return False
        result = self.handle_request(request)
        try:
            survey_requests.write_result(
                request["id"], result["ok"], result["message"], result["data"],
                request_dir=self.request_dir)
        except Exception:
            logger.exception("could not write the result of request %s", request.get('id'))
        return True

    def run(self, stop_event):
        """Main loop: reconcile, then serve requests until stopped."""
        self.startup()
        last_status = time.monotonic()
        last_cleanup = time.monotonic()
        last_recover = time.monotonic()

        while not stop_event.is_set():
            # Drain all pending requests
            while self.run_once():
                pass

            now = time.monotonic()

            # Periodic status check (lets controller auto-apply completed survey)
            if now - last_status >= self.status_interval:
                try:
                    self.controller.get_status()
                except Exception:
                    logger.exception("error getting survey status")
                last_status = now

            # Periodic recovery retry (resume interrupted survey when receiver is ready)
            if getattr(self.controller, 'recovery_pending', False):
                if now - last_recover >= self.recover_retry_interval:
                    last_recover = now
                    try:
                        resumed = self.controller.recover_survey()
                        if resumed:
                            logger.info("reconcile retry: resumed an interrupted survey")
                        else:
                            logger.info("reconcile retry: still waiting to resume (receiver not ready)")
                    except Exception:
                        logger.exception("reconcile retry failed")

            # Periodic cleanup of stale request files
            if now - last_cleanup >= self.cleanup_interval:
                try:
                    survey_requests.cleanup_stale(request_dir=self.request_dir)
                except Exception:
                    logger.exception("error cleaning up stale requests")
                last_cleanup = now

            stop_event.wait(self.poll_interval)


def main(argv=None):
    """Entry point for the systemd service."""
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s %(levelname)s %(name)s: %(message)s',
        stream=sys.stderr)

    # Lazy import of the survey controller
    from .survey_controller import SurveyController

    def cors_manager_factory(controller):
        """Build the CORS job manager with the controller's dependencies."""
        from ..cors_position.cors_job import CorsJobManager
        from .rtkbase_config import RTKBaseConfig
        from .state_manager import SurveyState
        from .survey_controller import _announce_planned_disconnect

        return CorsJobManager(
            rtkbase_factory=lambda: RTKBaseConfig(str(controller.rtkbase.settings_file)),
            restart=controller.restart_rtkbase_services,
            announce=lambda: _announce_planned_disconnect(controller.rtkbase, "cors_position"),
            survey_running=lambda: controller.state.survey_state == SurveyState.RUNNING)

    runner = SurveyRunner(SurveyController, cors_manager_factory=cors_manager_factory)
    stop_event = threading.Event()

    def handle_signal(signum, frame):
        logger.info("received signal %d", signum)
        stop_event.set()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    logger.info("survey runner started")
    runner.run(stop_event)
    logger.info("survey runner stopping (the persisted survey state is left untouched "
                "so the survey resumes on the next start)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
