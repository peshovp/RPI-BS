"""
Runtime data directory for Autosurvey/PPP-AR working files.

CONFIRMED LIVE (test station, 2026-10-01): geomaxima_survey/ (RINEX
conversions, per-slot pdp3 work dirs) and geomaxima_geoid/ (uploaded geoid
model + its config) were being created directly under the git checkout
root (self.rtkbase.rtkbase_root), alongside geomaxima_ppp/ (ANTEX +
precise-product cache). Runtime data written inside the working tree is
exactly what previously made an OTA's `git reset --hard` fail or leave
root-owned files behind (see tools/repo_update.sh / commit aac3a0f) - even
though these particular directories are owned by the install user, not
root, they still show up as untracked clutter in `git status` and, if ever
written by a root-run process, would reintroduce the same class of bug.

GM_RUNTIME_DIR is the single base directory for this kind of data, kept
OUTSIDE the checkout, next to the other state this project already keeps
in /var/lib/rtkbase (survey_state.json, dns_status.json, the OTA
controller's state - see update_controller.py's OTA_STATE_DIR for the
identical pattern). GM_RUNTIME_DIR itself is an env var test seam (never
set in production) so tests can point it at a temp directory instead of
the real /var/lib/rtkbase.
"""

import os
from pathlib import Path

GM_RUNTIME_DIR = Path(os.environ.get('GM_RUNTIME_DIR', '/var/lib/rtkbase'))
