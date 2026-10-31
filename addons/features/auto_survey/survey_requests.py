"""File-based request/result protocol between web app and survey runner.

Layout:
    <request_dir>/pending/<name>.json   queued requests (FIFO by filename)
    <request_dir>/results/<id>.json     completed results
    <request_dir>/rejected/<name>.json  unreadable/invalid requests

Atomicity: all writes use a temp file (leading dot) then os.replace().
FIFO: request filenames are zero-padded nanosecond timestamps.
"""

import json
import os
import time
import uuid
from typing import Optional

DEFAULT_REQUEST_DIR = "/var/lib/rtkbase/survey_requests"
ALLOWED_ACTIONS = ("start", "stop", "reset", "cors_compute", "cors_cancel", "cors_apply", "apply_proposal")


def _ensure_dirs(request_dir: str) -> None:
    for sub in ("pending", "results", "rejected"):
        os.makedirs(os.path.join(request_dir, sub), mode=0o700, exist_ok=True)


def _atomic_write(path: str, data: dict) -> None:
    tmp = os.path.join(os.path.dirname(path), f".tmp-{uuid.uuid4().hex}")
    with open(tmp, "w") as f:
        json.dump(data, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def submit_request(action: str, params=None, *, request_dir=DEFAULT_REQUEST_DIR) -> str:
    """Submit a survey request. Returns the request ID."""
    if action not in ALLOWED_ACTIONS:
        raise ValueError(f"action must be one of {ALLOWED_ACTIONS}, got {action!r}")
    if params is not None and not isinstance(params, dict):
        raise ValueError("params must be None or a dict")

    _ensure_dirs(request_dir)
    request_id = uuid.uuid4().hex
    pending_dir = os.path.join(request_dir, "pending")

    ts = time.time_ns()
    filename = f"{ts:020d}-{request_id}.json"
    path = os.path.join(pending_dir, filename)

    request = {
        "id": request_id,
        "action": action,
        "params": params or {},
        "submitted_at": time.time(),
    }
    _atomic_write(path, request)
    return request_id


def take_next_request(*, request_dir=DEFAULT_REQUEST_DIR) -> Optional[dict]:
    """Take the next pending request (FIFO). Returns None if none available."""
    pending_dir = os.path.join(request_dir, "pending")
    if not os.path.isdir(pending_dir):
        return None

    try:
        files = sorted(
            f for f in os.listdir(pending_dir)
            if f.endswith(".json") and not f.startswith(".")
        )
    except OSError:
        return None

    for filename in files:
        path = os.path.join(pending_dir, filename)
        try:
            with open(path, "r") as f:
                request = json.load(f)
        except (OSError, json.JSONDecodeError):
            _move_to_rejected(path, request_dir)
            continue

        if not isinstance(request, dict):
            _move_to_rejected(path, request_dir)
            continue
        if not isinstance(request.get("id"), str):
            _move_to_rejected(path, request_dir)
            continue
        if request.get("action") not in ALLOWED_ACTIONS:
            _move_to_rejected(path, request_dir)
            continue
        if not isinstance(request.get("params"), dict):
            _move_to_rejected(path, request_dir)
            continue

        try:
            os.unlink(path)
        except OSError:
            continue

        return request

    return None


def _move_to_rejected(path: str, request_dir: str) -> None:
    """Move an invalid request to the rejected directory."""
    try:
        rejected_dir = os.path.join(request_dir, "rejected")
        os.makedirs(rejected_dir, mode=0o700, exist_ok=True)
        dest = os.path.join(rejected_dir, os.path.basename(path))
        os.replace(path, dest)
    except OSError:
        pass


def cancel_request(request_id: str, *, request_dir=DEFAULT_REQUEST_DIR) -> bool:
    """Cancel a pending request by ID.

    Only a request that has not been taken yet can be cancelled.
    Returns True if a request was removed, False otherwise.
    """
    pending_dir = os.path.join(request_dir, "pending")
    if not os.path.isdir(pending_dir):
        return False

    suffix = f"-{request_id}.json"
    removed = False
    try:
        for filename in os.listdir(pending_dir):
            if filename.endswith(suffix) and not filename.startswith("."):
                path = os.path.join(pending_dir, filename)
                try:
                    os.unlink(path)
                    removed = True
                except OSError:
                    pass
    except OSError:
        pass

    return removed


def write_result(request_id: str, ok: bool, message: str = "", data=None, *,
                 request_dir=DEFAULT_REQUEST_DIR) -> None:
    """Write a result for a request."""
    _ensure_dirs(request_dir)
    results_dir = os.path.join(request_dir, "results")
    path = os.path.join(results_dir, f"{request_id}.json")

    result = {
        "id": request_id,
        "ok": bool(ok),
        "message": str(message),
        "data": data,
        "finished_at": time.time(),
    }
    _atomic_write(path, result)


def wait_for_result(request_id: str, timeout: float, *, poll_interval=0.2,
                    request_dir=DEFAULT_REQUEST_DIR) -> Optional[dict]:
    """Wait for a result, returning it or None on timeout."""
    results_dir = os.path.join(request_dir, "results")
    path = os.path.join(results_dir, f"{request_id}.json")
    deadline = time.monotonic() + timeout

    while time.monotonic() < deadline:
        if os.path.exists(path):
            try:
                with open(path, "r") as f:
                    result = json.load(f)
                os.unlink(path)
                return result
            except json.JSONDecodeError:
                time.sleep(poll_interval)
                continue
            except OSError:
                time.sleep(poll_interval)
                continue
        time.sleep(poll_interval)

    return None


def cleanup_stale(max_age_seconds=3600, *, request_dir=DEFAULT_REQUEST_DIR) -> int:
    """Delete stale result and rejected files. Returns count deleted."""
    now = time.time()
    deleted = 0

    for sub in ("results", "rejected"):
        dir_path = os.path.join(request_dir, sub)
        if not os.path.isdir(dir_path):
            continue
        try:
            for filename in os.listdir(dir_path):
                if filename.startswith("."):
                    continue
                path = os.path.join(dir_path, filename)
                try:
                    mtime = os.path.getmtime(path)
                    if now - mtime > max_age_seconds:
                        os.unlink(path)
                        deleted += 1
                except OSError:
                    pass
        except OSError:
            pass

    return deleted
