"""CORS/NTRIP rover account store.

Manages credentials for multiple CORS networks. Accounts are stored in a
root-only JSON file; passwords are never exposed in public listings, logs,
or audit events.
"""

import json
import os
import re
import threading
import time
import uuid
from typing import Any, Dict, List, Optional, Tuple

DEFAULT_ACCOUNTS_FILE = "/var/lib/rtkbase/cors_accounts.json"
MAX_ACCOUNTS = 10
FRAMES = ("ETRF2000@2005.0", "ETRF2000@epoch", "ITRF2020@epoch", "WGS84-approx")
MODES = ("vrs", "single_base")

try:
    from audit_logger import log_event
except ImportError:
    try:
        from web_app.audit_logger import log_event
    except ImportError:
        log_event = lambda *a, **k: None

_lock = threading.Lock()

_HOST_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$")
_MOUNTPOINT_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")


class CorsAccountsError(Exception):
    """Error reading, writing, or validating the CORS accounts store."""
    pass


def _validate_epoch_frame(frame: Optional[str], epoch: Any) -> Optional[str]:
    """Check epoch/frame consistency. Returns error string or None."""
    if frame is None:
        return None
    if frame.endswith("@epoch"):
        if epoch is None:
            return "epoch is required when frame ends with @epoch"
        if not isinstance(epoch, (int, float)):
            return "epoch must be a number"
        if not (1990.0 <= epoch <= 2100.0):
            return "epoch must be between 1990.0 and 2100.0"
    else:
        if epoch is not None:
            return "epoch must be absent when frame does not end with @epoch"
    return None


def validate_account(data: Dict[str, Any], partial: bool = False) -> Tuple[Dict[str, Any], List[str]]:
    """Validate an account record.

    Returns (cleaned_record, errors). If partial=True, only present fields
    are validated and returned; no defaults are applied.
    """
    errors: List[str] = []
    clean: Dict[str, Any] = {}

    allowed_keys = {
        "name", "host", "port", "mountpoint", "username", "password",
        "tls", "mode", "frame", "epoch", "enabled",
        "use_for_crosscheck", "use_for_quick_start",
    }

    for key in data:
        if key not in allowed_keys:
            errors.append(f"unknown field: {key}")

    # name
    if "name" in data:
        name = data["name"]
        if not isinstance(name, str):
            errors.append("name must be a string")
        else:
            name = name.strip()
            if not (1 <= len(name) <= 64):
                errors.append("name must be 1-64 characters")
            else:
                clean["name"] = name
    elif not partial:
        errors.append("name is required")

    # host
    if "host" in data:
        host = data["host"]
        if not isinstance(host, str):
            errors.append("host must be a string")
        elif not _HOST_RE.match(host):
            errors.append("host must be a valid hostname or IPv4 address")
        else:
            clean["host"] = host
    elif not partial:
        errors.append("host is required")

    # port
    if "port" in data:
        port = data["port"]
        if isinstance(port, bool) or not isinstance(port, int):
            errors.append("port must be an integer")
        elif not (1 <= port <= 65535):
            errors.append("port must be 1-65535")
        else:
            clean["port"] = port
    elif not partial:
        errors.append("port is required")

    # mountpoint
    if "mountpoint" in data:
        mp = data["mountpoint"]
        if not isinstance(mp, str):
            errors.append("mountpoint must be a string")
        elif not (1 <= len(mp) <= 100):
            errors.append("mountpoint must be 1-100 characters")
        elif not _MOUNTPOINT_RE.match(mp):
            errors.append("mountpoint contains invalid characters")
        else:
            clean["mountpoint"] = mp
    elif not partial:
        errors.append("mountpoint is required")

    # username
    if "username" in data:
        un = data["username"]
        if not isinstance(un, str):
            errors.append("username must be a string")
        elif not (1 <= len(un) <= 128):
            errors.append("username must be 1-128 characters")
        elif _CONTROL_RE.search(un):
            errors.append("username contains control characters")
        else:
            clean["username"] = un
    elif not partial:
        errors.append("username is required")

    # password
    if "password" in data:
        pw = data["password"]
        if not isinstance(pw, str):
            errors.append("password must be a string")
        elif not (1 <= len(pw) <= 128):
            errors.append("password must be 1-128 characters")
        elif _CONTROL_RE.search(pw):
            errors.append("password contains control characters")
        else:
            clean["password"] = pw
    elif not partial:
        errors.append("password is required")

    # tls
    if "tls" in data:
        if not isinstance(data["tls"], bool):
            errors.append("tls must be a boolean")
        else:
            clean["tls"] = data["tls"]
    elif not partial:
        clean["tls"] = False

    # mode
    if "mode" in data:
        if data["mode"] not in MODES:
            errors.append("mode must be one of: " + ", ".join(MODES))
        else:
            clean["mode"] = data["mode"]
    elif not partial:
        clean["mode"] = "vrs"

    # frame
    if "frame" in data:
        if data["frame"] not in FRAMES:
            errors.append("frame must be one of: " + ", ".join(FRAMES))
        else:
            clean["frame"] = data["frame"]
    elif not partial:
        clean["frame"] = "ETRF2000@2005.0"

    # epoch
    if "epoch" in data:
        epoch = data["epoch"]
        if epoch is not None:
            if not isinstance(epoch, (int, float)):
                errors.append("epoch must be a number or null")
            elif not (1990.0 <= epoch <= 2100.0):
                errors.append("epoch must be between 1990.0 and 2100.0")
            else:
                clean["epoch"] = epoch
        else:
            clean["epoch"] = None
    elif not partial:
        clean["epoch"] = None

    # Check epoch/frame consistency
    if not partial:
        # Always check for full validation (use cleaned values with defaults)
        frame_err = _validate_epoch_frame(clean.get("frame"), clean.get("epoch"))
        if frame_err:
            errors.append(frame_err)
    # For partial validation, skip the check — update_account checks the merged record

    # enabled
    if "enabled" in data:
        if not isinstance(data["enabled"], bool):
            errors.append("enabled must be a boolean")
        else:
            clean["enabled"] = data["enabled"]
    elif not partial:
        clean["enabled"] = True

    # use_for_crosscheck
    if "use_for_crosscheck" in data:
        if not isinstance(data["use_for_crosscheck"], bool):
            errors.append("use_for_crosscheck must be a boolean")
        else:
            clean["use_for_crosscheck"] = data["use_for_crosscheck"]
    elif not partial:
        clean["use_for_crosscheck"] = True

    # use_for_quick_start
    if "use_for_quick_start" in data:
        if not isinstance(data["use_for_quick_start"], bool):
            errors.append("use_for_quick_start must be a boolean")
        else:
            clean["use_for_quick_start"] = data["use_for_quick_start"]
    elif not partial:
        clean["use_for_quick_start"] = False

    return clean, errors


def load_accounts(path: str = DEFAULT_ACCOUNTS_FILE) -> List[Dict[str, Any]]:
    """Load all accounts from the store file.

    Returns a list of full account records (including passwords).
    Raises CorsAccountsError if the file is unreadable or corrupt.
    """
    if not os.path.exists(path):
        return []

    try:
        with open(path, "r") as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError):
        raise CorsAccountsError("accounts store is unreadable")

    if not isinstance(data, dict) or "accounts" not in data:
        raise CorsAccountsError("accounts store is unreadable")

    accounts = data["accounts"]
    if not isinstance(accounts, list):
        raise CorsAccountsError("accounts store is unreadable")

    # Validate that all items are dicts
    for item in accounts:
        if not isinstance(item, dict):
            raise CorsAccountsError("accounts store is unreadable")

    return accounts


def _save_accounts(accounts: List[Dict[str, Any]], path: str) -> None:
    """Atomically save accounts to the store file."""
    directory = os.path.dirname(path)
    if directory and not os.path.exists(directory):
        os.makedirs(directory, mode=0o700)

    # Build unique temp path first
    tmp_path = os.path.join(directory or ".", f".cors_accounts_{uuid.uuid4().hex}.tmp")

    # Then open it
    fd = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump({"version": 1, "accounts": accounts}, f)
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


def public_view(record: Dict[str, Any]) -> Dict[str, Any]:
    """Return a copy of the record without the password."""
    view = {k: v for k, v in record.items() if k != "password"}
    view["has_password"] = True
    return view


def list_accounts(path: str = DEFAULT_ACCOUNTS_FILE) -> List[Dict[str, Any]]:
    """List all accounts (public view, no passwords)."""
    with _lock:
        accounts = load_accounts(path)
        return [public_view(a) for a in accounts]


def get_account(account_id: str, path: str = DEFAULT_ACCOUNTS_FILE) -> Dict[str, Any]:
    """Get a full account record by ID (internal use)."""
    with _lock:
        accounts = load_accounts(path)
        for a in accounts:
            if a.get("id") == account_id:
                return a
        raise CorsAccountsError("unknown account")


def create_account(data: Dict[str, Any], path: str = DEFAULT_ACCOUNTS_FILE) -> Dict[str, Any]:
    """Create a new account. Returns the public view."""
    clean, errors = validate_account(data, partial=False)
    if errors:
        raise CorsAccountsError("; ".join(errors))

    with _lock:
        accounts = load_accounts(path)
        if len(accounts) >= MAX_ACCOUNTS:
            raise CorsAccountsError("account limit reached")

        account_id = uuid.uuid4().hex[:12]
        clean["id"] = account_id
        clean["created_at"] = int(time.time())
        accounts.append(clean)
        _save_accounts(accounts, path)

        log_event("cors", "account_created", {"id": account_id, "name": clean["name"]})
        return public_view(clean)


def update_account(account_id: str, data: Dict[str, Any], path: str = DEFAULT_ACCOUNTS_FILE) -> Dict[str, Any]:
    """Update an existing account. Returns the public view."""
    # If password is empty string or None, keep the stored password
    if data.get("password") == "" or data.get("password") is None:
        data = {k: v for k, v in data.items() if k != "password"}

    clean, errors = validate_account(data, partial=True)
    if errors:
        raise CorsAccountsError("; ".join(errors))

    with _lock:
        accounts = load_accounts(path)
        target = None
        for a in accounts:
            if a.get("id") == account_id:
                target = a
                break
        if target is None:
            raise CorsAccountsError("unknown account")

        # Track changed fields for audit
        changed_fields = []
        for key, value in clean.items():
            if target.get(key) != value:
                changed_fields.append(key)
            target[key] = value

        # If frame changed to non-epoch frame and epoch not in patch, clear epoch
        if "frame" in clean and not clean["frame"].endswith("@epoch") and "epoch" not in clean:
            if target.get("epoch") is not None:
                target["epoch"] = None
                if "epoch" not in changed_fields:
                    changed_fields.append("epoch")

        # Re-check epoch/frame consistency on merged record
        frame_err = _validate_epoch_frame(target.get("frame"), target.get("epoch"))
        if frame_err:
            raise CorsAccountsError(frame_err)

        _save_accounts(accounts, path)

        log_event("cors", "account_updated", {
            "id": account_id,
            "name": target["name"],
            "fields": sorted(changed_fields),
        })
        return public_view(target)


def delete_account(account_id: str, path: str = DEFAULT_ACCOUNTS_FILE) -> bool:
    """Delete an account. Returns True if deleted, False if not found."""
    with _lock:
        accounts = load_accounts(path)
        target = None
        for a in accounts:
            if a.get("id") == account_id:
                target = a
                break
        if target is None:
            return False

        accounts = [a for a in accounts if a.get("id") != account_id]
        _save_accounts(accounts, path)

        log_event("cors", "account_deleted", {"id": account_id, "name": target["name"]})
        return True
