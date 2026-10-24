"""Check availability of precise GNSS products needed for PPP-AR processing.

The final PPP-AR position can only be computed when the daily precise products
(orbit and ERP, tier RAP or FIN) exist for every UTC day touched by the
observation window. These products are published by WHU approximately 13-19
hours after the day ends. This module provides a cheap directory-listing check
to avoid running the full processing pipeline when products are not yet ready.

Fail-open on errors: if the remote listing fails, the caller proceeds anyway.
"""

import ftplib
import os
from datetime import datetime, timedelta

WHU_HOST = "igs.gnsswhu.cn"
WHU_DIR_TEMPLATE = "/pub/whu/phasebias/{year}/orbit"


def utc_days(window_start, window_end):
    """Return list of (year, doy) tuples for each UTC day touched by the window.

    The window end is exclusive. A window ending exactly at 00:00:00 does not
    touch the next day.
    """
    last_instant = window_end - timedelta(seconds=1)
    if last_instant < window_start:
        last_instant = window_start

    days = []
    current = window_start
    while current <= last_instant:
        tt = current.timetuple()
        days.append((tt.tm_year, tt.tm_yday))
        # Move to start of next day
        next_day = datetime(current.year, current.month, current.day) + timedelta(days=1)
        current = next_day

    return days


def product_names(year, doy):
    """Return dict of acceptable product filenames for the given day.

    Keys: 'erp', 'orbit'. Each value is a list of filenames; any one suffices.
    """
    erp = []
    orbit = []
    for tier in ('RAP', 'FIN'):
        erp.append(f"WUM0MGX{tier}_{year}{doy:03d}0000_01D_01D_ERP.ERP.gz")
        orbit.append(f"WUM0MGX{tier}_{year}{doy:03d}0000_01D_05M_ORB.SP3.gz")
    return {'erp': erp, 'orbit': orbit}


def list_remote_files(year, timeout=30.0, ftp_factory=None):
    """List files in the WHU product directory for the given year.

    Returns a set of filenames. Lets exceptions propagate.
    """
    directory = WHU_DIR_TEMPLATE.format(year=year)
    ftp = (ftp_factory or ftplib.FTP)(WHU_HOST, timeout=timeout)
    try:
        ftp.login()
        ftp.cwd(directory)
        names = ftp.nlst()
    finally:
        try:
            ftp.close()
        except Exception:
            pass
    return {os.path.basename(n) for n in names}


def check_products_available(window_start, window_end, lister=None):
    """Check whether all required products are available for the window.

    Returns dict with keys:
      'available': True, False, or None (error)
      'missing': list of strings describing missing products
      'error': None or error text
    """
    if lister is None:
        lister = list_remote_files

    days = utc_days(window_start, window_end)

    # Cache listings per year
    listings = {}
    missing = []

    for year, doy in days:
        if year not in listings:
            try:
                listings[year] = lister(year)
            except Exception as e:
                return {
                    'available': None,
                    'missing': [],
                    'error': f"{type(e).__name__}: {e}"
                }

        listing = listings[year]
        names = product_names(year, doy)

        if not any(n in listing for n in names['erp']):
            missing.append(f"{year} DOY {doy}: ERP")
        if not any(n in listing for n in names['orbit']):
            missing.append(f"{year} DOY {doy}: orbit")

    return {
        'available': len(missing) == 0,
        'missing': missing,
        'error': None
    }
