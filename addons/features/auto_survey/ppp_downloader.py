"""
Precise Product Downloader for PPP-static Processing
======================================================

Downloads SP3 (precise orbit) and CLK (precise clock) products from CDDIS,
authenticated via NASA Earthdata Login, for use by PPPProcessor (Phase 2c).

BACKGROUND (see design_ppp_static_migration.md, "Phase 2a: Verification Gate
Results" for full evidence): igs.ign.fr and the WHU mirror were confirmed
UNREACHABLE from station network during Phase 2a testing. CDDIS
(cddis.nasa.gov) was confirmed reachable but requires NASA Earthdata Login -
anonymous requests are redirected to an OAuth login page, and a naive
`requests.get()` following that redirect will silently save the LOGIN PAGE
ITSELF (an HTML document) as if it were the requested binary product. This
module defends against that failure mode explicitly (see
_validate_downloaded_product()).

CDDIS's exact current directory/filename convention was NOT confirmed during
Phase 2a (every attempt hit the auth wall before a real filename could be
tested). This module's URL construction is written against CDDIS's publicly
documented layout as of this writing.

A live test on BS-Aheloy with real Earthdata credentials subsequently found
that the original login implementation never actually authenticated -
`requests` strips Authorization headers on cross-host redirects, so
Basic Auth credentials attached via `session.auth` never reached
urs.earthdata.nasa.gov. This has been fixed with a manual redirect-replay
login (see PPPDownloader._ensure_session()/_login_via_redirect()), but the
FIX ITSELF has not yet been live-tested. See _KNOWN_LIMITATIONS at the
bottom of this file.

IMPORTANT ASYMMETRY - ULTRA-RAPID HAS NO SEPARATE CLK FILE: unlike rapid
and final (each of which publishes distinct SP3 orbit and CLK clock
products), the IGS COMBINED ultra-rapid product only publishes an SP3
file. A full authenticated CDDIS directory listing confirmed zero
IGS0OPSULT_*_CLK.CLK.gz entries exist for any date in GPS week 2430 -
per documented IGS convention, ultra-rapid's satellite clock offsets are
embedded directly inside the SP3 file itself (for the observed half of
the window) rather than published as a separate, higher-precision CLK
product. fetch_products() therefore returns {"sp3": Path, "clk": Path}
for tier in ("rapid", "final"), but only {"sp3": Path} (no "clk" key) for
tier == "ultra-rapid" - see _fetch_ultra_rapid_with_retry()'s docstring
for the full explanation. This is a structural fact about the product,
not a bug to fix later - do not add a clk fetch attempt for ultra-rapid.
"""

import gzip
import logging
import os
import shutil
import subprocess
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Dict, Literal, Optional

logger = logging.getLogger(__name__)

CDDIS_BASE_URL = "https://cddis.nasa.gov/archive/gnss/products"

Tier = Literal["ultra-rapid", "rapid", "final"]

# Typical publication latency per tier, used only for the "auto" tier-picker
# in fetch_products() - not used to gate whether a download is attempted,
# since actual availability can vary and the real signal is always the HTTP
# response, not a guess based on elapsed time.
_TIER_LATENCY_HOURS = {
    "ultra-rapid": 0,      # predicted/observed halves published every 6h
    "rapid": 41,            # up to ~41h
    "final": 18 * 24,       # up to ~18 days
}


class PPPDownloaderError(Exception):
    """Base class for all ppp_downloader errors."""


class NoCredentialsConfiguredError(PPPDownloaderError):
    """No Earthdata username/password found in settings.conf."""


class CredentialsRejectedError(PPPDownloaderError):
    """CDDIS/Earthdata rejected the provided credentials (HTTP 401/403)."""


class ProductNotPublishedError(PPPDownloaderError):
    """The requested tier/date combination is not yet available (HTTP 404)."""


class NetworkUnreachableError(PPPDownloaderError):
    """Could not reach CDDIS at all (DNS/connect/timeout failure)."""


class InvalidProductContentError(PPPDownloaderError):
    """
    Downloaded content failed validation - most commonly an HTML auth-wall
    page saved where a binary SP3/CLK file was expected. This exact failure
    mode was directly observed during Phase 2a testing (a 200 OK response
    whose body was the Earthdata Login page, not product data).
    """


@dataclass
class GPSDate:
    """GPS week/day-of-week and calendar-based fields needed for CDDIS URLs."""
    gps_week: int
    day_of_week: int   # 0=Sunday .. 6=Saturday
    year: int
    day_of_year: int    # 1-366
    # The normalized (naive UTC) datetime this GPSDate was computed from,
    # retained so ultra-rapid's hour-mark selection (which needs the actual
    # hour/minute, not just the calendar day) doesn't have to reconstruct a
    # datetime from year+day_of_year and lose that information.
    reference_dt: datetime

    @property
    def wwwwd(self) -> str:
        """Legacy short-form identifier, e.g. '24302' for week 2430, day 2."""
        return f"{self.gps_week}{self.day_of_week}"


def compute_gps_date(dt: datetime) -> GPSDate:
    """
    Compute GPS week/day-of-week and year/day-of-year for a given UTC
    datetime. Ported from the shell logic validated in Phase 2a.

    GPS epoch: 1980-01-06 (Sunday).

    Accepts either naive or timezone-aware input. CALLERS (including
    fetch_products() and, later, survey_controller.py in Phase 2c/2d) MUST
    treat the input as UTC either way - a naive datetime is assumed to
    already be UTC (never local time), and an aware datetime is converted
    to UTC before use. This function never raises on mixed naive/aware
    input; it normalizes internally instead, since the GPS epoch constant
    below has no timezone of its own to compare against.
    """
    if dt.tzinfo is not None:
        dt = dt.astimezone(timezone.utc).replace(tzinfo=None)

    gps_epoch = datetime(1980, 1, 6)
    delta_days = (dt - gps_epoch).days
    gps_week = delta_days // 7
    day_of_week = delta_days % 7
    return GPSDate(
        gps_week=gps_week,
        day_of_week=day_of_week,
        year=dt.year,
        day_of_year=dt.timetuple().tm_yday,
        reference_dt=dt,
    )


def latest_ultra_rapid_hour_mark(dt: datetime) -> str:
    """
    Select the most recent ultra-rapid publication hour-mark ("0000", "0600",
    "1200", "1800") at or before the given UTC datetime.

    Ultra-rapid products are published 4x/day at these fixed hour marks
    (confirmed via a real authenticated CDDIS directory listing on
    BS-Aheloy, GPS week 2429/2430 range - e.g.
    IGS0OPSULT_20262070000_..., IGS0OPSULT_20262070600_...,
    IGS0OPSULT_20262071200_..., IGS0OPSULT_20262071800_...). Since
    ultra-rapid's whole purpose is "best available right now", picking a
    mark that hasn't been published yet (e.g. 1800 when it's currently
    14:32 UTC) would always 404 - this always rounds DOWN to the latest
    already-published mark, never up.

    Accepts naive or timezone-aware input, same convention as
    compute_gps_date().
    """
    if dt.tzinfo is not None:
        dt = dt.astimezone(timezone.utc).replace(tzinfo=None)

    marks = (0, 6, 12, 18)
    hour_mark = max(m for m in marks if m <= dt.hour)
    return f"{hour_mark:02d}00"


def generate_ultra_rapid_candidates(reference_dt: datetime, max_attempts: int = 8):
    """
    Generate a descending sequence of GPSDate candidates for ultra-rapid
    probing, starting from "now, rounded down to the latest published 6h
    mark" and stepping backward 6 hours at a time (correctly crossing day
    boundaries via timedelta subtraction) for up to max_attempts candidates.

    WHY THIS EXISTS: a live authenticated CDDIS directory listing on
    BS-Aheloy (GPS week 2430, captured 2026-08-04T15:55 UTC) showed the
    most recently published IGS0OPSULT file was for day-of-year 215
    (2026-08-03) hour-mark 1200 - i.e. no file existed yet for day 215
    hour 1800, nor for day 216 (the capture day) at all. Ultra-rapid
    publication latency is NOT the fixed "round down to today's latest 6h
    mark" the earlier fix assumed - it can lag by up to a day or more
    depending on analysis center processing time. Deterministically
    guessing a single hour-mark is not reliable; the only robust approach
    is to probe backward until a real file is found.

    max_attempts=8 covers up to 48 hours back (8 * 6h), which comfortably
    covers the ~1-day lag observed on BS-Aheloy while remaining a small,
    bounded number of requests rather than an open-ended search.

    Yields GPSDate objects, most recent candidate first.
    """
    dt = reference_dt
    if dt.tzinfo is not None:
        dt = dt.astimezone(timezone.utc).replace(tzinfo=None)

    marks = (0, 6, 12, 18)
    latest_mark = max(m for m in marks if m <= dt.hour)
    candidate_dt = dt.replace(hour=latest_mark, minute=0, second=0, microsecond=0)

    for _ in range(max_attempts):
        yield compute_gps_date(candidate_dt)
        candidate_dt = candidate_dt - timedelta(hours=6)


def _get_credentials(settings_file: Optional[str] = None) -> Dict[str, str]:
    """
    Read Earthdata username/password from settings.conf via
    web_app/ppp_earthdata_settings.py (the same reader used by the Settings
    UI), reused here rather than reimplementing config parsing.
    """
    try:
        import sys
        _web_app_dir = os.path.abspath(
            os.path.join(os.path.dirname(__file__), "../../../../web_app")
        )
        if _web_app_dir not in sys.path:
            sys.path.insert(0, _web_app_dir)
        from ppp_earthdata_settings import get_earthdata_settings
    except ImportError as e:
        raise PPPDownloaderError(f"Could not import ppp_earthdata_settings: {e}")

    settings = get_earthdata_settings(settings_file)
    values = {}
    for item in settings[1:]:
        values.update(item)

    if not values.get("username") or not values.get("password"):
        raise NoCredentialsConfiguredError(
            "No Earthdata Login credentials configured. Set them in the "
            "Settings tab under Auto Survey-In > PPP-static / Earthdata Login."
        )
    return values


def _validate_downloaded_product(content: bytes, filename: str) -> None:
    """
    Guard against the exact failure mode observed in Phase 2a: a 200 OK
    response whose body is the Earthdata Login HTML page, not the requested
    binary product. Raises InvalidProductContentError if the content looks
    like HTML rather than a compressed SP3/CLK file.
    """
    if len(content) < 100:
        raise InvalidProductContentError(
            f"{filename}: downloaded content is implausibly small "
            f"({len(content)} bytes) to be a real product file"
        )

    head = content[:512].lstrip()
    if head[:1] in (b"<",) or b"<html" in head.lower() or b"<!doctype" in head.lower():
        raise InvalidProductContentError(
            f"{filename}: downloaded content is HTML, not a binary product "
            f"(this is the auth-wall failure mode confirmed in Phase 2a - "
            f"credentials were not accepted, or the session did not "
            f"complete the Earthdata OAuth handshake)"
        )

    # .gz files start with the magic bytes 1f 8b; legacy .Z files start with
    # 1f 9d. Anything else, for a filename claiming one of those extensions,
    # is suspicious.
    if filename.endswith(".gz") and content[:2] != b"\x1f\x8b":
        raise InvalidProductContentError(
            f"{filename}: claims .gz extension but does not have gzip magic bytes"
        )
    if filename.endswith(".Z") and content[:2] != b"\x1f\x9d":
        raise InvalidProductContentError(
            f"{filename}: claims .Z extension but does not have compress(1) magic bytes"
        )


def _decompress(compressed_path: Path) -> Path:
    """
    Decompress a downloaded .gz or .Z file. .gz is handled via the stdlib
    gzip module (no new dependency). .Z (legacy Unix compress/LZW) is NOT
    decompressible by Python's stdlib gzip module - GNU gzip's `gzip -d`
    binary handles both formats natively (confirmed: GNU gzip auto-detects
    and decompresses .Z/LZW input despite the name), and gzip is already a
    base OS package on the target Raspberry Pi OS image, so no new
    install.sh dependency is introduced here.
    """
    suffix = compressed_path.suffix
    output_path = compressed_path.with_suffix("")

    if suffix == ".gz":
        with gzip.open(compressed_path, "rb") as f_in, open(output_path, "wb") as f_out:
            shutil.copyfileobj(f_in, f_out)
        return output_path

    if suffix == ".Z":
        gzip_bin = shutil.which("gzip")
        if gzip_bin is None:
            raise PPPDownloaderError(
                "gzip binary not found in PATH - required to decompress .Z "
                "legacy-format precise products. gzip is expected to already "
                "be present on the base OS image; if missing, add it to "
                "install.sh's apt-get package list."
            )
        result = subprocess.run(
            [gzip_bin, "-d", "-k", "-f", str(compressed_path)],
            capture_output=True, text=True, timeout=60
        )
        if result.returncode != 0:
            raise PPPDownloaderError(
                f"Failed to decompress {compressed_path}: {result.stderr}"
            )
        return output_path

    raise PPPDownloaderError(f"Unrecognized compression suffix on {compressed_path}: {suffix}")


class PPPDownloader:
    """
    Downloads SP3/CLK precise products from CDDIS, authenticated via NASA
    Earthdata Login.

    Accepts an optional injected requests.Session and credentials dict for
    testability (per Phase 2b requirements) - callers in production code
    should leave both as None and let credentials be read from
    settings.conf automatically.
    """

    def __init__(self,
                 products_dir: Path,
                 credentials: Optional[Dict[str, str]] = None,
                 session=None,
                 settings_file: Optional[str] = None):
        self.products_dir = Path(products_dir)
        self.products_dir.mkdir(parents=True, exist_ok=True)
        self._settings_file = settings_file
        self._credentials = credentials
        self._session = session

    def _ensure_session(self):
        """
        Lazily create and authenticate a requests.Session against Earthdata
        Login, unless one was injected (for tests).

        AUTH FLOW - CONFIRMED BROKEN, THEN FIXED, VIA LIVE TESTING ON
        BS-AHELOY WITH REAL EARTHDATA CREDENTIALS:

        The original implementation set `session.auth = (username,
        password)` and relied on `requests`' automatic redirect-following
        (CDDIS -> urs.earthdata.nasa.gov -> back to CDDIS) to deliver those
        credentials to the login host. Live testing showed this does NOT
        work: `requests` deliberately strips the Authorization header on
        any redirect that crosses to a different host (documented,
        intentional `requests` security behavior - see
        https://requests.readthedocs.io/en/latest/user/authentication/,
        "the Authorization header will be removed if you get redirected
        off-host"). Since CDDIS's product URLs redirect to
        urs.earthdata.nasa.gov, the credentials never actually reached the
        login host - the login page was served anonymously and returned as
        a 200 OK, which _download_one() correctly identified as
        InvalidProductContentError (HTML, not a binary product), rather
        than the CredentialsRejectedError a real 401/403 would produce.

        FIX - matches NASA's own documented EDL scripted-access pattern
        (the same approach used by NASA's own example download scripts,
        e.g. the podaac-tools/GES-DISC "wget/curl without .netrc" examples,
        which manually replay the redirect with Basic Auth attached rather
        than relying on a single auto-followed request):
          1. Issue the request to the CDDIS product URL with
             allow_redirects=False, to capture the redirect Location header
             pointing at urs.earthdata.nasa.gov WITHOUT `requests` silently
             stripping anything (no redirect is followed yet, so nothing to
             strip).
          2. Issue a SEPARATE, explicit request directly to that
             urs.earthdata.nasa.gov URL, with Basic Auth passed via the
             `auth=` parameter on that one call (not `session.auth`, so it
             is never subject to the same-session redirect-stripping logic
             either). Because this request targets urs.earthdata.nasa.gov
             directly (not a redirect hop within a single call), the
             Authorization header is actually sent.
          3. That login exchange sets session cookies (via the shared
             requests.Session cookie jar) that authenticate subsequent
             requests back to cddis.nasa.gov. Follow any further redirects
             from that response (allow_redirects=True is safe here - by
             this point the session is cookie-authenticated, so credential
             stripping on redirect is a non-issue).
          4. Re-issue the ORIGINAL CDDIS product URL request. The session
             cookie jar now carries the CDDIS-side session, so this second
             attempt should receive the actual binary product instead of
             another redirect to the login page.

        This exchange happens once per PPPDownloader instance (session
        cookies persist for the life of the requests.Session), not on every
        product download - see _login_via_redirect() and its call site in
        _download_one().
        """
        if self._session is not None:
            return self._session

        try:
            import requests
        except ImportError:
            raise PPPDownloaderError(
                "The 'requests' package is required but not installed. "
                "It is already listed in web_app/requirements.txt and "
                "addons/requirements.txt - run pip install -r on the "
                "appropriate requirements file."
            )

        creds = self._credentials or _get_credentials(self._settings_file)

        session = requests.Session()
        # Deliberately NOT session.auth = (...) here - that was the root
        # cause of the bug described above. Credentials are applied
        # explicitly, once, in _login_via_redirect() instead.
        self._session = session
        self._creds = creds
        self._logged_in = False
        return session

    def _login_via_redirect(self, product_url: str):
        """
        Perform the manual redirect-replay login exchange described in
        _ensure_session()'s docstring, using product_url as the trigger
        request whose redirect chain we need to authenticate through.

        No-op if already logged in this session (cookies persist across
        multiple product downloads within one PPPDownloader instance).
        """
        session = self._session
        if getattr(self, "_logged_in", False):
            return

        try:
            initial = session.get(product_url, timeout=60, allow_redirects=False)
        except Exception as e:
            raise NetworkUnreachableError(f"Could not reach {product_url}: {e}")

        if initial.status_code not in (301, 302, 303, 307, 308):
            # No redirect at all - either already authenticated (unlikely
            # on a fresh session) or CDDIS is serving something unexpected.
            # Either way, there's nothing to log in to; let the normal
            # _download_one() flow handle whatever this response actually is.
            self._logged_in = True
            return

        login_url = initial.headers.get("Location")
        if not login_url:
            raise PPPDownloaderError(
                f"CDDIS returned redirect status {initial.status_code} for "
                f"{product_url} but no Location header - cannot proceed with login"
            )

        try:
            login_resp = session.get(
                login_url,
                auth=(self._creds["username"], self._creds["password"]),
                timeout=60,
                allow_redirects=True,
            )
        except Exception as e:
            raise NetworkUnreachableError(f"Could not reach Earthdata Login at {login_url}: {e}")

        if login_resp.status_code in (401, 403):
            raise CredentialsRejectedError(
                f"Earthdata Login rejected credentials at {login_url} "
                f"(HTTP {login_resp.status_code})"
            )

        self._logged_in = True

    def _build_url(self, product_type: str, tier: Tier, gps_date: GPSDate) -> str:
        """
        Construct the CDDIS download URL for a given product type
        ("sp3" or "clk"), tier, and GPS date.

        Long-filename convention confirmed via a real authenticated CDDIS
        directory listing on BS-Aheloy
        (https://cddis.nasa.gov/archive/gnss/products/2429/), rapid tier:
            IGS0OPSRAP_20262130000_01D_15M_ORB.SP3.gz   (SP3: 15-min interval)
            IGS0OPSRAP_20262130000_01D_05M_CLK.CLK.gz   (CLK: 5-min interval)
        The sampling-interval token ("15M" vs "05M") differs by PRODUCT TYPE,
        not just by tier - SP3 orbit products use a 15-minute interval, CLK
        clock products use a 5-minute interval. This was the actual cause of
        a live ProductNotPublishedError on CLK downloads (the code
        previously hardcoded "15M" for both product types).

        ASSUMPTION, NOT INDEPENDENTLY CONFIRMED: the 15M/05M split above was
        only observed for the "rapid" tier's directory listing. This
        function applies the same per-product-type interval uniformly to
        "ultra-rapid" and "final" as well, since IGS's stated convention is
        that the interval reflects product type rather than tier - but no
        real directory listing for ultra-rapid or final has been inspected
        to confirm this holds for those two tiers specifically.

        ULTRA-RAPID DIFFERS IN TWO MORE WAYS, both confirmed via a real
        authenticated CDDIS directory listing on BS-Aheloy (GPS week
        2429/2430 range):
            IGS0OPSULT_20262070000_02D_15M_ORB.SP3.gz
            IGS0OPSULT_20262070600_02D_15M_ORB.SP3.gz
            IGS0OPSULT_20262071200_02D_15M_ORB.SP3.gz
            IGS0OPSULT_20262071800_02D_15M_ORB.SP3.gz
        (1) the day-span token is "02D" (ultra-rapid spans a 2-day window -
            observed + predicted half), not "01D" like rapid/final; (2)
        the timestamp's hour field is one of 0000/0600/1200/1800 (4
        publications/day), not always "0000" - see
        latest_ultra_rapid_hour_mark() for how the correct, already-published
        mark is selected.
        """
        tier_infix = {"ultra-rapid": "ULT", "rapid": "RAP", "final": "FIN"}[tier]
        product_infix = {"sp3": "ORB", "clk": "CLK"}[product_type]
        ext = "SP3" if product_type == "sp3" else "CLK"
        # Confirmed for "rapid" via live CDDIS listing (see docstring above);
        # applied uniformly to all tiers as an unconfirmed assumption for
        # ultra-rapid/final.
        interval = {"sp3": "15M", "clk": "05M"}[product_type]
        day_span = "02D" if tier == "ultra-rapid" else "01D"
        hour_mark = latest_ultra_rapid_hour_mark(gps_date.reference_dt) if tier == "ultra-rapid" else "0000"

        yyyyddd = f"{gps_date.year}{gps_date.day_of_year:03d}"
        filename = f"IGS0OPS{tier_infix}_{yyyyddd}{hour_mark}_{day_span}_{interval}_{product_infix}.{ext}.gz"
        # Directory layout: /archive/gnss/products/<gps_week>/
        return f"{CDDIS_BASE_URL}/{gps_date.gps_week}/{filename}"

    def _build_legacy_url(self, product_type: str, tier: Tier, gps_date: GPSDate) -> str:
        """
        Legacy short-form fallback URL (igu/igr/igs + WWWWD), per §5 of
        the design doc. Documented fallback only - not the primary attempt.

        For ultra-rapid, CDDIS's legacy short-form already encodes the same
        4x/day hour-mark concept as a "_00"/"_06"/"_12"/"_18" filename
        suffix (matching the four hour marks confirmed in _build_url()'s
        docstring) - this was previously hardcoded to always "_00", which
        would 404 for any time after the first publication of the day, same
        root cause as the long-form URL's bug.
        """
        tier_prefix = {"ultra-rapid": "igu", "rapid": "igr", "final": "igs"}[tier]
        ext = "sp3" if product_type == "sp3" else "clk"
        if tier == "ultra-rapid":
            legacy_hour_suffix = latest_ultra_rapid_hour_mark(gps_date.reference_dt)[:2]
            filename = f"{tier_prefix}{gps_date.wwwwd}_{legacy_hour_suffix}.{ext}.Z"
        else:
            filename = f"{tier_prefix}{gps_date.wwwwd}.{ext}.Z"
        return f"{CDDIS_BASE_URL}/{gps_date.gps_week}/{filename}"

    def _download_one(self, url: str) -> Path:
        """
        Download a single product file, validate it isn't an auth-wall
        HTML page, decompress it, and return the local decompressed path.
        """
        session = self._ensure_session()
        self._login_via_redirect(url)

        filename = url.rsplit("/", 1)[-1]
        compressed_path = self.products_dir / filename

        try:
            resp = session.get(url, timeout=60, allow_redirects=True)
        except Exception as e:
            # requests raises ConnectionError/Timeout/etc for unreachable hosts
            raise NetworkUnreachableError(f"Could not reach {url}: {e}")

        if resp.status_code in (401, 403):
            raise CredentialsRejectedError(
                f"CDDIS/Earthdata rejected credentials for {url} (HTTP {resp.status_code})"
            )
        if resp.status_code == 404:
            raise ProductNotPublishedError(
                f"Product not found at {url} (HTTP 404) - not yet published "
                f"for this tier/date, or the naming convention is wrong "
                f"(see _build_url() docstring - unverified against live CDDIS)"
            )
        if resp.status_code != 200:
            raise PPPDownloaderError(f"Unexpected HTTP {resp.status_code} for {url}")

        _validate_downloaded_product(resp.content, filename)

        with open(compressed_path, "wb") as f:
            f.write(resp.content)

        return _decompress(compressed_path)

    def fetch_products(self, tier: Tier, survey_start_time: datetime) -> Dict[str, Path]:
        """
        Public entry point matching the Phase 2b-requested signature
        (download_precise_products in the task description; named
        fetch_products here to match §5 of the design doc - same
        signature/behavior, kept consistent with the design document
        already on disk).

        :param tier: "ultra-rapid" | "rapid" | "final"
        :param survey_start_time: the survey/data window start, in UTC.
            Both naive (assumed already UTC) and timezone-aware datetimes
            are accepted - see compute_gps_date() for the exact
            normalization rule. Callers should be consistent about which
            form they pass, but either works correctly.
        :return: for tier in ("rapid", "final"): {"sp3": Path, "clk": Path}.
            For tier == "ultra-rapid": {"sp3": Path} ONLY - see
            _fetch_ultra_rapid_with_retry()'s docstring for why no separate
            clk file exists for this tier. CALLERS (eventually
            PPPProcessor in Phase 2c) MUST check tier before assuming a
            "clk" key is present in the returned dict.

        Raises NoCredentialsConfiguredError, CredentialsRejectedError,
        ProductNotPublishedError, NetworkUnreachableError, or
        InvalidProductContentError - callers should not treat any of these
        as a reason to silently fall back to SPP; per Pesho's explicit
        "no fallback, no silent start" decision, a failed precise-product
        fetch should surface as a failed survey update, not a silent
        degrade to broadcast ephemeris.
        """
        if tier not in ("ultra-rapid", "rapid", "final"):
            raise ValueError(f"Unknown tier: {tier!r}")

        if tier == "ultra-rapid":
            return self._fetch_ultra_rapid_with_retry(survey_start_time)

        gps_date = compute_gps_date(survey_start_time)

        result = {}
        for product_type in ("sp3", "clk"):
            url = self._build_url(product_type, tier, gps_date)
            try:
                result[product_type] = self._download_one(url)
            except ProductNotPublishedError:
                # Try the legacy short-form URL as a documented fallback
                # before giving up - see _build_legacy_url() docstring.
                legacy_url = self._build_legacy_url(product_type, tier, gps_date)
                logger.warning(
                    f"Long-form URL 404'd for {product_type}/{tier}, "
                    f"trying legacy short-form: {legacy_url}"
                )
                result[product_type] = self._download_one(legacy_url)

        return result

    def _fetch_ultra_rapid_with_retry(self, survey_start_time: datetime,
                                       max_attempts: int = 8) -> Dict[str, Path]:
        """
        Ultra-rapid-only probe/retry variant of fetch_products(). NOT used
        for rapid/final - those tiers' single-URL-per-product-type approach
        is already confirmed working end-to-end on BS-Aheloy and is left
        untouched by this method.

        Publication latency for ultra-rapid is variable (see
        generate_ultra_rapid_candidates()'s docstring for the live evidence
        that motivated this) - a single deterministic hour-mark guess is
        not reliable. This instead probes a descending sequence of
        candidate (day, hour-mark) pairs, most recent first, trying the
        long-form URL then the legacy short-form fallback at each candidate
        (same per-candidate fallback behavior fetch_products() already uses
        for rapid/final), and stops at the first candidate where sp3
        succeeds.

        NO SEPARATE CLK FILE FOR ULTRA-RAPID: a full authenticated CDDIS
        directory listing for GPS week 2430 showed IGS0OPSULT_*.SP3.gz
        entries but ZERO IGS0OPSULT_*_CLK.CLK.gz entries anywhere in the
        listing (other analysis centers, e.g. GRG0OPSULT/WHU0OPSULT, DO
        publish a separate ultra-rapid clk product - but this module
        requests the IGS COMBINED product specifically, which does not).
        This matches documented IGS convention: the ultra-rapid combined
        SP3 file has satellite clock offset values embedded directly in the
        SP3 format itself for the observed half of the window, rather than
        a separate higher-precision CLK product the way rapid/final have.
        Consequently this method only ever fetches "sp3" - attempting a
        "clk" fetch here would always 404 regardless of which candidate
        date/hour-mark is tried, which is what originally caused every one
        of the 8 probe candidates to be exhausted before this fix.

        Returns {"sp3": Path} - NO "clk" key, unlike rapid/final's
        {"sp3": Path, "clk": Path}. See fetch_products()'s docstring.

        Raises ProductNotPublishedError, with a clear summary of how many
        candidates were tried and the date/hour range covered, if every
        candidate 404s. Any other exception (auth failure, network
        unreachable, invalid content) propagates immediately rather than
        being treated as "try the next candidate" - those are not
        publication-latency issues and retrying a different date won't fix
        them.
        """
        candidates = list(generate_ultra_rapid_candidates(survey_start_time, max_attempts))

        for attempt_num, gps_date in enumerate(candidates, start=1):
            candidate_label = (
                f"{gps_date.year}-day{gps_date.day_of_year:03d} "
                f"{gps_date.reference_dt.hour:02d}00 UTC"
            )
            logger.info(
                f"Ultra-rapid probe attempt {attempt_num}/{len(candidates)}: "
                f"trying {candidate_label}"
            )
            try:
                url = self._build_url("sp3", "ultra-rapid", gps_date)
                try:
                    sp3_path = self._download_one(url)
                except ProductNotPublishedError:
                    legacy_url = self._build_legacy_url("sp3", "ultra-rapid", gps_date)
                    logger.debug(
                        f"Ultra-rapid long-form URL 404'd for sp3 "
                        f"at {candidate_label}, trying legacy short-form: {legacy_url}"
                    )
                    sp3_path = self._download_one(legacy_url)

                logger.info(f"Ultra-rapid probe succeeded at {candidate_label} (attempt {attempt_num})")
                return {"sp3": sp3_path}

            except ProductNotPublishedError:
                logger.debug(f"Ultra-rapid probe miss at {candidate_label} (attempt {attempt_num}) - trying older candidate")
                continue

        oldest = candidates[-1]
        newest = candidates[0]
        raise ProductNotPublishedError(
            f"Ultra-rapid product not found after {len(candidates)} probe attempts, "
            f"covering {oldest.year}-day{oldest.day_of_year:03d} "
            f"{oldest.reference_dt.hour:02d}00 UTC through "
            f"{newest.year}-day{newest.day_of_year:03d} "
            f"{newest.reference_dt.hour:02d}00 UTC"
        )

    def ensure_antex(self, bundled_path: Optional[Path] = None) -> Path:
        """
        Returns a path to an ANTEX (.atx) file for satellite/receiver
        antenna PCO/PCV corrections.

        Per §5/§7 of the design doc: ANTEX changes infrequently (new IGS
        conventions every few years, not per-survey), so this should be a
        STATIC, BUNDLED repo asset rather than downloaded fresh every
        survey. This method does not implement downloading at all - it
        only resolves a bundled file's path, and raises if it's missing,
        so the absence of a required asset fails loudly rather than
        silently proceeding without antenna corrections (which would
        silently degrade PPP accuracy by several cm, defeating the purpose
        of this migration).

        Bundling the actual .atx file is a separate, still-open action item
        - see design_ppp_static_migration.md Phase 2b open questions.
        """
        if bundled_path is None:
            bundled_path = Path(__file__).parent / "igs20.atx"

        if not bundled_path.exists():
            raise PPPDownloaderError(
                f"ANTEX file not found at {bundled_path}. Per the design "
                f"doc, this should be bundled as a static repo asset "
                f"(e.g. addons/features/auto_survey/igs20.atx) rather than "
                f"downloaded per-survey - it has not yet been added. "
                f"Download a current one from "
                f"https://files.igs.org/pub/station/general/ and place it "
                f"at this path."
            )
        return bundled_path


# ---------------------------------------------------------------------------
# _KNOWN_LIMITATIONS - carried into design_ppp_static_migration.md verbatim.
# ---------------------------------------------------------------------------
# 1. The original session.auth-based redirect-following login was LIVE
#    TESTED on BS-Aheloy with real Earthdata credentials and CONFIRMED
#    BROKEN (requests strips Authorization headers on cross-host redirects,
#    so credentials never reached urs.earthdata.nasa.gov - the login page
#    was returned anonymously as a 200 OK). It has been replaced with the
#    manual redirect-replay login in _login_via_redirect() (see
#    _ensure_session()'s docstring for the full explanation). This NEW flow
#    has NOT yet been live-tested - Pesho must re-run the same live test on
#    BS-Aheloy to confirm it actually authenticates before Phase 2c/2d can
#    depend on this module working end-to-end.
# 2. _build_url()'s long-filename convention is still UNVERIFIED against
#    live CDDIS - the previous live test never got far enough to reach a
#    real product URL response (it failed at the login step, bug 2 above).
#    The legacy-format fallback in fetch_products() is likewise still
#    unverified.
# 3. No ANTEX file is bundled yet - ensure_antex() will raise until one is
#    added to the repo (see its docstring).
