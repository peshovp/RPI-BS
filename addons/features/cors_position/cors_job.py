"""CORS position computation job manager.

Runs one CORS position computation in the background, keeps its state in a
root-only JSON file, compares the proposal with the current broadcast
position, and applies it only after an explicit confirmation.
"""

import calendar
import json
import logging
import math
import os
import shutil
import threading
import time
import uuid
from datetime import datetime, timezone
from typing import Any, Callable, Dict, List, Optional, Tuple

from . import cors_accounts as accounts
from . import cors_rtk
from . import cors_apply
from . import cors_frame

try:
    from audit_logger import log_event
except ImportError:
    try:
        from web_app.audit_logger import log_event
    except ImportError:
        log_event = lambda *a, **k: None

logger = logging.getLogger(__name__)

DEFAULT_JOB_FILE = "/var/lib/rtkbase/cors_job.json"
DEFAULT_WORK_ROOT = "/var/lib/rtkbase/cors_work"

CROSSCHECK_HORIZONTAL_M = 0.03
CROSSCHECK_VERTICAL_M = 0.05

BGS2005_FRAME = "ETRF2000@2005.0"

# Keys from compute_position result that are safe to store (no secrets)
SAFE_RESULT_KEYS = [
    "ok", "stage", "kind", "reason", "account_id", "account_name",
    "frame", "epoch", "mode", "approx", "base_xyz", "summary",
    "lat", "lon", "h", "rover_bytes", "base_bytes",
    "started_at", "finished_at",
]


def _decimal_year(iso_text):
    """Parse an ISO 8601 UTC timestamp string and return the decimal year.

    Returns None for None or unparsable text.
    """
    if iso_text is None:
        return None
    try:
        dt = datetime.fromisoformat(iso_text)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        day_of_year = dt.timetuple().tm_yday
        seconds_of_day = (dt.hour * 3600 + dt.minute * 60 + dt.second)
        days_in_year = 366 if calendar.isleap(dt.year) else 365
        return dt.year + (day_of_year - 1 + seconds_of_day / 86400) / days_in_year
    except (ValueError, TypeError, AttributeError):
        return None


def load_job(path: str = DEFAULT_JOB_FILE) -> Optional[Dict[str, Any]]:
    """Load the current job from the job file.

    Returns None if the file is missing or unreadable.
    """
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return None
        return data
    except (json.JSONDecodeError, OSError):
        return None


def save_job(job: Dict[str, Any], path: str = DEFAULT_JOB_FILE) -> None:
    """Atomically save the job to the job file."""
    directory = os.path.dirname(path)
    if directory and not os.path.exists(directory):
        os.makedirs(directory, mode=0o700)

    tmp_path = os.path.join(directory or ".", f".cors_job_{uuid.uuid4().hex}.tmp")
    fd = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(job, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, path)
        os.chmod(path, 0o600)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def compare_positions(
    proposal: Tuple[float, float, float],
    current: Optional[Tuple[float, float, float]]
) -> Optional[Dict[str, Any]]:
    """Compare a proposed position with the current broadcast position.

    Returns None if current is None. Otherwise returns a dict with
    d_north_m, d_east_m, d_up_m, horizontal_m, vertical_m,
    within_threshold, and hint.
    """
    if current is None:
        return None

    dlat = proposal[0] - current[0]
    dlon = proposal[1] - current[1]
    dh = proposal[2] - current[2]

    d_north_m = dlat * 111132.92
    d_east_m = dlon * 111412.84 * math.cos(math.radians(current[0]))
    d_up_m = dh

    horizontal_m = math.sqrt(d_north_m ** 2 + d_east_m ** 2)
    vertical_m = abs(d_up_m)

    within = (horizontal_m <= CROSSCHECK_HORIZONTAL_M and
              vertical_m <= CROSSCHECK_VERTICAL_M)

    if within:
        hint = "consistent with the current position"
    elif horizontal_m < 1.5 and vertical_m < 3.0:
        hint = "small difference: the network may use a different epoch or realisation"
    else:
        hint = "large difference: check the coordinate system of this network"

    return {
        "d_north_m": d_north_m,
        "d_east_m": d_east_m,
        "d_up_m": d_up_m,
        "horizontal_m": horizontal_m,
        "vertical_m": vertical_m,
        "within_threshold": within,
        "hint": hint,
    }


class CorsJobManager:
    """Manages a single CORS position computation job."""

    def __init__(
        self,
        rtkbase_factory: Callable[[], Any],
        accounts_path: str = accounts.DEFAULT_ACCOUNTS_FILE,
        job_path: str = DEFAULT_JOB_FILE,
        work_root: str = DEFAULT_WORK_ROOT,
        compute_fn: Optional[Callable] = None,
        apply_fn: Optional[Callable] = None,
        convert_fn: Optional[Callable] = None,
        restart: Optional[Callable] = None,
        announce: Optional[Callable] = None,
        survey_running: Optional[Callable[[], bool]] = None,
        audit: Optional[Callable] = None,
    ):
        self._rtkbase_factory = rtkbase_factory
        self._accounts_path = accounts_path
        self._job_path = job_path
        self._work_root = work_root
        self._compute_fn = compute_fn or cors_rtk.compute_position
        self._apply_fn = apply_fn or cors_apply.apply_position
        self._convert_fn = convert_fn or cors_frame.to_bgs2005
        self._restart = restart
        self._announce = announce
        self._survey_running = survey_running or (lambda: False)
        self._audit = audit or log_event
        self._lock = threading.Lock()
        self._thread: Optional[threading.Thread] = None
        self._stop_event = threading.Event()
        self._applied_job_ids = set()

        # Reconcile stale running job from previous service instance
        try:
            self.status()
        except Exception:
            logger.exception("Failed to reconcile stale CORS job on init")

        # Clean up leftover work directories from previous runs
        try:
            if os.path.exists(self._work_root):
                for entry in os.listdir(self._work_root):
                    entry_path = os.path.join(self._work_root, entry)
                    try:
                        if os.path.isdir(entry_path):
                            shutil.rmtree(entry_path)
                        else:
                            os.remove(entry_path)
                    except Exception:
                        logger.exception("Failed to clean up work entry: %s", entry_path)
        except Exception:
            logger.exception("Failed to clean up CORS work root: %s", self._work_root)

    def start(
        self,
        account_id: str,
        params: Optional[Dict[str, Any]] = None
    ) -> Tuple[bool, str]:
        """Start a CORS position computation for the given account."""
        with self._lock:
            if self._thread is not None and self._thread.is_alive():
                return (False, "a CORS computation is already running")

            try:
                account = accounts.get_account(account_id, self._accounts_path)
            except accounts.CorsAccountsError:
                return (False, "unknown account")

            if not account.get("enabled", True):
                return (False, "account is disabled")

            job_id = uuid.uuid4().hex[:12]
            job = {
                "job_id": job_id,
                "status": "running",
                "stage": "starting",
                "info": "",
                "account_id": account_id,
                "account_name": account["name"],
                "frame": account["frame"],
                "epoch": account["epoch"],
                "mode": account["mode"],
                "arp_corrected": False,
                "started_at": datetime.now(timezone.utc).isoformat(),
                "finished_at": None,
                "result": None,
                "comparison": None,
                "converted": None,
                "conversion_error": None,
                "conversion_epoch": None,
                "applied_at": None,
                "apply_result": None,
                "last_apply_error": None,
            }
            save_job(job, self._job_path)

            self._audit("cors", "compute_started", {
                "job_id": job_id,
                "account_id": account_id,
                "account_name": account["name"],
            })

            self._stop_event.clear()
            self._thread = threading.Thread(
                target=self._run,
                args=(job_id, account, params),
                daemon=True,
            )
            self._thread.start()
            return (True, job_id)

    def _run(
        self,
        job_id: str,
        account: Dict[str, Any],
        params: Optional[Dict[str, Any]],
    ) -> None:
        """Run the CORS computation in a background thread."""
        try:
            if params is None:
                params = {}
            params = dict(params)

            # Determine rover suffix from receiver format
            try:
                rtkbase = self._rtkbase_factory()
                receiver_info = rtkbase.get_receiver_info()
                fmt = receiver_info.get("format", "ubx")
                params.setdefault("rover_suffix", f".{fmt}")
            except Exception:
                params.setdefault("rover_suffix", ".ubx")

            work_dir = os.path.join(self._work_root, job_id)

            def progress(stage: str, info: str) -> None:
                job = load_job(self._job_path)
                if job is not None and job.get("job_id") == job_id:
                    job["stage"] = stage
                    job["info"] = info
                    save_job(job, self._job_path)

            result = self._compute_fn(
                account, work_dir, params,
                progress=progress,
                stop_event=self._stop_event,
            )

            # Get current broadcast position for comparison
            current = None
            try:
                rtkbase = self._rtkbase_factory()
                current = rtkbase.get_position()
            except Exception:
                pass

            # Convert to BGS2005 if we have a position
            converted = None
            conversion_error = None
            conv_epoch = account["epoch"]
            if result.get("lat") is not None:
                if account["frame"].endswith("@date"):
                    conv_epoch = _decimal_year(result.get("finished_at")) or _decimal_year(datetime.now(timezone.utc).isoformat())
                try:
                    converted = self._convert_fn(
                        result["lat"], result["lon"], result["h"],
                        account["frame"], conv_epoch
                    )
                except cors_frame.FrameError as e:
                    conversion_error = str(e)
                except Exception:
                    conversion_error = "the frame conversion failed"

            # Use converted position for comparison when available
            comparison = None
            if result.get("lat") is not None:
                if converted is not None:
                    proposal = (converted["lat"], converted["lon"], converted["h"])
                else:
                    proposal = (result["lat"], result["lon"], result["h"])
                comparison = compare_positions(proposal, current)

            # Determine status
            if result.get("ok"):
                status = "done"
            elif result.get("kind") == "cancelled":
                status = "cancelled"
            else:
                status = "failed"

            # Store only safe keys from result
            safe_result = {k: result.get(k) for k in SAFE_RESULT_KEYS if k in result}

            # Store only safe keys from converted
            safe_converted = None
            if converted is not None:
                safe_converted = {
                    k: converted.get(k) for k in (
                        "lat", "lon", "h", "method", "shift_m",
                        "shift_n_m", "shift_e_m", "shift_u_m",
                        "provisional", "provisional_reason"
                    )
                }

            job = load_job(self._job_path)
            if job is None or job.get("job_id") != job_id:
                job = {
                    "job_id": job_id,
                    "status": status,
                    "stage": result.get("stage", "unknown"),
                    "info": result.get("reason", ""),
                    "account_id": account["id"],
                    "account_name": account["name"],
                    "frame": account["frame"],
                    "epoch": account["epoch"],
                    "mode": account["mode"],
                    "arp_corrected": False,
                    "started_at": job.get("started_at") if job else None,
                    "finished_at": datetime.now(timezone.utc).isoformat(),
                    "result": safe_result,
                    "comparison": comparison,
                    "converted": safe_converted,
                    "conversion_error": conversion_error,
                    "conversion_epoch": conv_epoch,
                    "applied_at": None,
                    "apply_result": None,
                    "last_apply_error": None,
                }
            else:
                job["status"] = status
                job["stage"] = result.get("stage", "unknown")
                job["info"] = result.get("reason", "")
                job["finished_at"] = datetime.now(timezone.utc).isoformat()
                job["result"] = safe_result
                job["comparison"] = comparison
                job["converted"] = safe_converted
                job["conversion_error"] = conversion_error
                job["conversion_epoch"] = conv_epoch

            save_job(job, self._job_path)

            # Audit compute finished
            summary = safe_result.get("summary") or {}
            self._audit("cors", "compute_finished", {
                "job_id": job_id,
                "status": status,
                "stage": result.get("stage"),
                "kind": result.get("kind"),
                "reason": result.get("reason"),
                "fixed": summary.get("fixed"),
                "used": summary.get("used"),
                "fix_ratio": summary.get("fix_ratio"),
                "horizontal_m": comparison["horizontal_m"] if comparison else None,
                "vertical_m": comparison["vertical_m"] if comparison else None,
                "std_n_m": summary.get("std_n_m"),
                "std_u_m": summary.get("std_u_m"),
            })

        except Exception:
            logger.exception("Unexpected error in CORS computation")
            job = load_job(self._job_path)
            if job is None or job.get("job_id") != job_id:
                job = {
                    "job_id": job_id,
                    "status": "failed",
                    "stage": "internal",
                    "info": "internal error",
                    "account_id": account["id"],
                    "account_name": account["name"],
                    "frame": account["frame"],
                    "epoch": account["epoch"],
                    "mode": account["mode"],
                    "arp_corrected": False,
                    "started_at": job.get("started_at") if job else None,
                    "finished_at": datetime.now(timezone.utc).isoformat(),
                    "result": None,
                    "comparison": None,
                    "converted": None,
                    "conversion_error": None,
                    "conversion_epoch": None,
                    "applied_at": None,
                    "apply_result": None,
                    "last_apply_error": None,
                }
            else:
                job["status"] = "failed"
                job["stage"] = "internal"
                job["info"] = "internal error"
                job["finished_at"] = datetime.now(timezone.utc).isoformat()
                job["result"] = None
                job["converted"] = None
                job["conversion_error"] = None
                job["conversion_epoch"] = None
            save_job(job, self._job_path)

    def cancel(self) -> bool:
        """Request cancellation of the running computation."""
        with self._lock:
            if self._thread is not None and self._thread.is_alive():
                self._stop_event.set()
                self._audit("cors", "compute_cancel_requested", {})
                return True
            return False

    def status(self) -> Dict[str, Any]:
        """Get the current job status."""
        with self._lock:
            job = load_job(self._job_path)
            if job is None:
                return {"status": "idle"}

            # Check if a running job was interrupted by a restart
            if job.get("status") == "running":
                if self._thread is None or not self._thread.is_alive():
                    job["status"] = "failed"
                    job["stage"] = "interrupted"
                    job["info"] = "the computation was interrupted by a restart"
                    job["finished_at"] = datetime.now(timezone.utc).isoformat()
                    save_job(job, self._job_path)
                    self._audit("cors", "compute_interrupted", {
                        "job_id": job.get("job_id"),
                    })

            return job

    def apply(
        self,
        job_id: str,
        confirmed: bool,
        force: bool = False,
    ) -> Dict[str, Any]:
        """Apply a confirmed CORS position proposal."""
        with self._lock:
            if confirmed is not True:
                self._audit("cors", "apply_refused", {
                    "job_id": job_id,
                    "reason": "confirmation required",
                })
                return {"ok": False, "reason": "confirmation required", "apply_result": None}

            job = load_job(self._job_path)

            if job is None or job.get("job_id") != job_id:
                self._audit("cors", "apply_refused", {
                    "job_id": job_id,
                    "reason": "no such computation",
                })
                return {"ok": False, "reason": "no such computation", "apply_result": None}

            if job_id in self._applied_job_ids:
                self._audit("cors", "apply_refused", {
                    "job_id": job_id,
                    "reason": "computation not finished successfully",
                })
                return {"ok": False, "reason": "computation not finished successfully", "apply_result": None}

            result = job.get("result") or {}
            if job.get("status") != "done" or not result.get("ok"):
                self._audit("cors", "apply_refused", {
                    "job_id": job_id,
                    "reason": "computation not finished successfully",
                })
                return {"ok": False, "reason": "computation not finished successfully", "apply_result": None}

            # Check for converted BGS2005 position
            converted = job.get("converted")
            if not converted:
                reason = "no BGS2005 position could be derived: " + (job.get("conversion_error") or "unknown reason")
                self._audit("cors", "apply_refused", {
                    "job_id": job_id,
                    "reason": reason,
                })
                return {"ok": False, "reason": reason, "apply_result": None}

            if self._survey_running():
                self._audit("cors", "apply_refused", {
                    "job_id": job_id,
                    "reason": "a survey is running",
                })
                return {"ok": False, "reason": "a survey is running", "apply_result": None}

            # Build metadata for apply
            summary = result.get("summary") or {}
            frame_epoch = job.get("conversion_epoch")
            if frame_epoch is None:
                frame_epoch = job.get("epoch")
            meta = {
                "account_name": job.get("account_name"),
                "frame": result.get("frame"),
                "frame_epoch": frame_epoch,
                "conversion": converted.get("method"),
                "frame_shift_m": converted.get("shift_m"),
                "provisional": converted.get("provisional", False),
                "fixed": summary.get("fixed"),
                "used": summary.get("used"),
                "fix_ratio": summary.get("fix_ratio"),
                "std_n_m": summary.get("std_n_m"),
                "std_e_m": summary.get("std_e_m"),
                "std_u_m": summary.get("std_u_m"),
                "job_id": job_id,
                "arp_corrected": False,
                "note": "antenna phase centre position, not corrected to the ARP",
            }

            res = self._apply_fn(
                self._rtkbase_factory(),
                converted["lat"], converted["lon"], converted["h"],
                source="cors",
                meta=meta,
                restart=self._restart,
                announce=self._announce,
                force=force,
                audit=self._audit,
            )

            if res.get("ok"):
                self._applied_job_ids.add(job_id)
                job["status"] = "applied"
                job["applied_at"] = datetime.now(timezone.utc).isoformat()
                job["apply_result"] = res
                try:
                    save_job(job, self._job_path)
                except Exception:
                    logger.exception("Failed to save applied job state for %s", job_id)
                return {"ok": True, "reason": None, "apply_result": res}
            else:
                job["last_apply_error"] = res.get("reason")
                save_job(job, self._job_path)
                return {"ok": False, "reason": res.get("reason"), "apply_result": res}
