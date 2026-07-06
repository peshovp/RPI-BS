import json
import os
from datetime import datetime
from pathlib import Path

AUDIT_LOG_PATH = Path("/var/lib/rtkbase/audit.log")

def log_event(category: str, event: str, details: dict = None):
    """
    Append a structured audit event as a JSON line.
    category: e.g. "service", "auto_survey"
    event: short event name, e.g. "start_requested", "survey_failed"
    details: optional dict with extra context (service name, reason, etc.)
    """
    entry = {
        "timestamp": datetime.utcnow().isoformat(),
        "category": category,
        "event": event,
        "details": details or {}
    }
    try:
        AUDIT_LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with open(AUDIT_LOG_PATH, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception as e:
        print(f"Audit log write failed: {e}")

def read_recent(limit: int = 200):
    """Return the most recent `limit` audit entries, newest first."""
    if not AUDIT_LOG_PATH.exists():
        return []
    try:
        with open(AUDIT_LOG_PATH, "r") as f:
            lines = f.readlines()[-limit:]
        entries = [json.loads(line) for line in lines if line.strip()]
        return list(reversed(entries))
    except Exception as e:
        print(f"Audit log read failed: {e}")
        return []
