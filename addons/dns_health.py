"""
DNS health: self-test of the system resolver, and classification of
network error text into "DNS resolution failed" vs. everything else.

Shared by the watchdog (periodic self-test + UI state), the PRIDE-PPPAR
processor (product-download failure diagnostics) and the OTA controller
(git fetch failures), so all three name a DNS failure the same way.

Policy (see tools/dns_setup.sh): the station uses only the DNS its own
network provides. Nothing here ever adds or suggests a public resolver;
if the network provides none, that is reported as an error.
"""

import json
import logging
import re
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional

logger = logging.getLogger(__name__)

# Hosts the station actually needs (same list as tools/dns_setup.sh):
# OTA and the PPP product mirrors.
DNS_TEST_HOSTS = ('github.com', 'bdspride.com', 'igs.gnsswhu.cn', 'igs.bkg.bund.de')
DNS_STATUS_FILE = Path('/var/lib/rtkbase/dns_status.json')
RESOLV_CONF = Path('/etc/resolv.conf')
_STUB_RESOLVERS = {'127.0.0.53', '127.0.0.54'}

# Text patterns meaning "the name could not be resolved" - as printed by
# curl (exit 6 "Could not resolve host", exit 28 "Resolving timed out"),
# wget ("unable to resolve host address", "Temporary failure in name
# resolution"), git (via curl) and glibc.
_DNS_PATTERNS = (
    re.compile(r"Could not resolve (?:host|proxy):?\s*'?(?P<host>[\w.-]+)?", re.I),
    re.compile(r"Resolving timed out", re.I),
    re.compile(r"curl: \(6\)", re.I),
    re.compile(r"unable to resolve host address\s*[‘'\"`]?(?P<host>[\w.-]+)?", re.I),
    re.compile(r"Temporary failure in name resolution", re.I),
    re.compile(r"Name or service not known", re.I),
    re.compile(r"No address associated with hostname", re.I),
)


def classify_network_error(text: str) -> Dict:
    """
    Classify error output. Returns {'dns': bool, 'hosts': [..], 'lines': [..]}
    where 'dns' is True if any line shows a name-resolution failure (as
    opposed to a server refusal, missing file, transfer stall, ...).
    """
    hosts: List[str] = []
    lines: List[str] = []
    for line in (text or '').splitlines():
        for pat in _DNS_PATTERNS:
            m = pat.search(line)
            if m:
                lines.append(line.strip())
                host = m.groupdict().get('host') if m.groupdict() else None
                if host and host not in hosts:
                    hosts.append(host)
                break
    return {'dns': bool(lines), 'hosts': hosts, 'lines': lines}


def system_nameservers() -> List[str]:
    """Nameservers the system resolver uses. For a systemd-resolved stub,
    the upstream servers it actually forwards to."""
    try:
        servers = [l.split()[1] for l in RESOLV_CONF.read_text().splitlines()
                   if l.startswith('nameserver') and len(l.split()) > 1]
    except OSError:
        return []
    if servers and set(servers) <= _STUB_RESOLVERS and shutil.which('resolvectl'):
        try:
            out = subprocess.run(['resolvectl', 'dns'], capture_output=True, text=True, timeout=5).stdout
            upstream = [tok for line in out.splitlines() for tok in line.split(':', 1)[-1].split()]
            return upstream
        except (OSError, subprocess.SubprocessError):
            return servers
    return servers


def _resolves(host: str, timeout: float) -> bool:
    # getent goes through glibc - the same path git/curl/wget use.
    try:
        return subprocess.run(['getent', 'ahostsv4', host], capture_output=True,
                              timeout=timeout).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def dns_self_test(hosts=DNS_TEST_HOSTS, timeout: float = 12.0) -> Dict:
    """
    Resolve `hosts` through the system resolver. Result 'status':
      'ok'      - all resolve
      'degraded'- some resolve
      'failed'  - none resolve, but the network does provide nameservers
      'no_dns'  - the network provides no nameserver at all
    """
    nameservers = system_nameservers()
    results = {h: _resolves(h, timeout) for h in hosts} if nameservers else {h: False for h in hosts}
    n_ok = sum(results.values())
    if not nameservers:
        status = 'no_dns'
        message = ("The network provides no DNS server (no nameserver in /etc/resolv.conf). "
                   "By policy no public resolver is added - fix DHCP or the station's static DNS setting.")
    elif n_ok == len(hosts):
        status, message = 'ok', f"all {n_ok} test hosts resolve via {', '.join(nameservers)}"
    elif n_ok:
        failed = [h for h, ok in results.items() if not ok]
        status, message = 'degraded', f"{n_ok}/{len(hosts)} resolve via {', '.join(nameservers)}; failed: {', '.join(failed)}"
    else:
        status, message = 'failed', f"no test host resolves via {', '.join(nameservers)}"
    return {
        'status': status,
        'message': message,
        'nameservers': nameservers,
        'results': results,
        'timestamp': datetime.now(timezone.utc).isoformat(timespec='seconds'),
    }


def save_status(status: Dict, path: Path = DNS_STATUS_FILE) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(status, indent=2))
    except OSError as e:
        logger.debug(f"could not write {path}: {e}")


def load_status(path: Path = DNS_STATUS_FILE) -> Optional[Dict]:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None
