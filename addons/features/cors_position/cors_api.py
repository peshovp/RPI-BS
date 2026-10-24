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
