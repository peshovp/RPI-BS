"""Flask-free request handlers for the CORS accounts HTTP API.

Each handler takes already-parsed input and returns (http_status, body_dict).
The account store module does the real work; these functions translate
store exceptions into HTTP responses.
"""

import re

try:
    from . import cors_accounts as store
except ImportError:
    import cors_accounts as store

_ACCOUNT_ID_RE = re.compile(r"^[A-Za-z0-9]{1,32}$")


def _error(exc):
    """Map a CorsAccountsError to (status, body_dict)."""
    msg = str(exc)
    if msg == "unknown account":
        return 404, {"ok": False, "error": "unknown account"}
    if msg == "account limit reached":
        return 409, {"ok": False, "error": "account limit reached"}
    if msg == "accounts store is unreadable":
        return 500, {"ok": False, "error": "accounts store is unreadable"}
    return 400, {"ok": False, "error": msg}


def handle_list(path=None):
    """List all accounts (public view)."""
    path = path or store.DEFAULT_ACCOUNTS_FILE
    try:
        accounts = store.list_accounts(path)
        return 200, {"ok": True, "accounts": accounts}
    except store.CorsAccountsError as exc:
        return _error(exc)
    except Exception:
        return 500, {"ok": False, "error": "internal error"}


def handle_create(body, path=None):
    """Create a new account."""
    path = path or store.DEFAULT_ACCOUNTS_FILE
    if not isinstance(body, dict):
        return 400, {"ok": False, "error": "JSON object required"}
    try:
        account = store.create_account(body, path)
        return 201, {"ok": True, "account": account}
    except store.CorsAccountsError as exc:
        return _error(exc)
    except Exception:
        return 500, {"ok": False, "error": "internal error"}


def handle_update(account_id, body, path=None):
    """Update an existing account."""
    path = path or store.DEFAULT_ACCOUNTS_FILE
    if not isinstance(account_id, str) or not _ACCOUNT_ID_RE.match(account_id):
        return 404, {"ok": False, "error": "unknown account"}
    if not isinstance(body, dict):
        return 400, {"ok": False, "error": "JSON object required"}
    try:
        account = store.update_account(account_id, body, path)
        return 200, {"ok": True, "account": account}
    except store.CorsAccountsError as exc:
        return _error(exc)
    except Exception:
        return 500, {"ok": False, "error": "internal error"}


def handle_delete(account_id, path=None):
    """Delete an account."""
    path = path or store.DEFAULT_ACCOUNTS_FILE
    if not isinstance(account_id, str) or not _ACCOUNT_ID_RE.match(account_id):
        return 404, {"ok": False, "error": "unknown account"}
    try:
        deleted = store.delete_account(account_id, path)
        if not deleted:
            return 404, {"ok": False, "error": "unknown account"}
        return 200, {"ok": True}
    except store.CorsAccountsError as exc:
        return _error(exc)
    except Exception:
        return 500, {"ok": False, "error": "internal error"}


def handle_compute(account_id, request_fn=None):
    """Request a CORS computation for an account."""
    if not isinstance(account_id, str) or not _ACCOUNT_ID_RE.match(account_id):
        return 404, {"ok": False, "error": "unknown account"}

    if request_fn is None:
        try:
            from . import cors_client
        except ImportError:
            import cors_client
        request_fn = cors_client.request

    try:
        result = request_fn("cors_compute", {"account_id": account_id})
    except RuntimeError:
        return 503, {"ok": False, "error": "the survey service is not available"}
    except Exception:
        return 500, {"ok": False, "error": "internal error"}

    if result is None:
        return 504, {"ok": False, "error": "the survey service did not answer in time"}

    if result.get("ok"):
        data = result.get("data") or {}
        return 202, {"ok": True, "job_id": data.get("job_id")}

    message = result.get("message", "")
    if message == "a CORS computation is already running":
        return 409, {"ok": False, "error": message}
    if message == "unknown account":
        return 404, {"ok": False, "error": message}
    if message == "account is disabled":
        return 409, {"ok": False, "error": message}
    return 400, {"ok": False, "error": message}


def handle_cancel(request_fn=None):
    """Cancel the current CORS computation."""
    if request_fn is None:
        try:
            from . import cors_client
        except ImportError:
            import cors_client
        request_fn = cors_client.request

    try:
        result = request_fn("cors_cancel", {})
    except RuntimeError:
        return 503, {"ok": False, "error": "the survey service is not available"}
    except Exception:
        return 500, {"ok": False, "error": "internal error"}

    if result is None:
        return 504, {"ok": False, "error": "the survey service did not answer in time"}

    if result.get("ok"):
        return 200, {"ok": True, "message": result.get("message", "")}
    return 400, {"ok": False, "error": result.get("message", "")}


def handle_apply(body, request_fn=None):
    """Apply the computed CORS position."""
    if not isinstance(body, dict):
        return 400, {"ok": False, "error": "JSON object required"}

    job_id = body.get("job_id")
    if not isinstance(job_id, str) or not re.match(r"^[A-Za-z0-9]{1,32}$", job_id):
        return 400, {"ok": False, "error": "job_id is required"}

    if body.get("confirm") is not True:
        return 400, {"ok": False, "error": "confirmation required"}

    force = body.get("force") is True

    if request_fn is None:
        try:
            from . import cors_client
        except ImportError:
            import cors_client
        request_fn = cors_client.request

    try:
        result = request_fn("cors_apply", {"job_id": job_id, "confirmed": True, "force": force})
    except RuntimeError:
        return 503, {"ok": False, "error": "the survey service is not available"}
    except Exception:
        return 500, {"ok": False, "error": "internal error"}

    if result is None:
        return 504, {"ok": False, "error": "the survey service did not answer in time"}

    if result.get("ok"):
        return 200, {"ok": True, "result": result.get("data")}
    return 409, {"ok": False, "error": result.get("message", ""), "result": result.get("data")}


def handle_job(job_path=None, runner_active_fn=None):
    """Get the current CORS job state."""
    try:
        try:
            from . import cors_job
        except ImportError:
            import cors_job

        path = job_path or cors_job.DEFAULT_JOB_FILE
        job = cors_job.load_job(path) or {"status": "idle"}

        if job.get("status") == "running":
            if runner_active_fn is None:
                try:
                    from . import cors_client
                except ImportError:
                    import cors_client
                runner_active_fn = cors_client.runner_active

            if not runner_active_fn():
                job = dict(job)
                job["status"] = "failed"
                job["stage"] = "interrupted"
                job["info"] = "the survey service is not running"

        return 200, {"ok": True, "job": job}
    except Exception:
        return 500, {"ok": False, "error": "internal error"}
