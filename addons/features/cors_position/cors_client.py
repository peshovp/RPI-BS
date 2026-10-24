"""Client for communicating with the survey runner service via the file request protocol."""

import subprocess

SERVICE_UNIT = "geomaxima_survey.service"


def runner_active():
    """Check if the survey runner service is active."""
    try:
        result = subprocess.run(
            ["systemctl", "is-active", SERVICE_UNIT],
            capture_output=True, text=True, timeout=10
        )
        return result.stdout.strip() == "active"
    except Exception:
        return False


def request(action, params=None, timeout=30.0, request_dir=None, start_service=None):
    """Submit a request to the survey runner and wait for the result."""
    from ..auto_survey import survey_requests

    if start_service is None:
        def start_service():
            try:
                result = subprocess.run(
                    ["systemctl", "start", SERVICE_UNIT],
                    capture_output=True, text=True, timeout=60
                )
                return result.returncode == 0
            except Exception:
                return False

    kw = {"request_dir": request_dir} if request_dir else {}

    request_id = survey_requests.submit_request(action, params, **kw)

    if not start_service():
        survey_requests.cancel_request(request_id, **kw)
        raise RuntimeError("the survey service could not be started")

    result = survey_requests.wait_for_result(request_id, timeout, **kw)
    if result is None:
        survey_requests.cancel_request(request_id, **kw)
    return result
