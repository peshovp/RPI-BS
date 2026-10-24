# External sources (so they are not lost)

Curated, annotated links used or worth using for GeoMaxima. Add new sources here with a one-line
"why it matters for us". Last review of the awesome-gnss list: 2026-10-24.

## Index lists

- **awesome-gnss** (https://github.com/barbeau/awesome-gnss) - broad, community list. Mostly
  Android/smartphone GNSS (raw measurements, jamming, urban datasets) which is NOT our domain.
  No sections on u-blox/Unicore receivers, ANTEX/antenna calibration, EUREF/EPN, time series or
  quality monitoring. The useful items are extracted below.

## Directly relevant to our pipeline

| Source | Why it matters for GeoMaxima |
|---|---|
| **RTKLIB** (http://www.rtklib.com/, https://github.com/tomojitakasu/RTKLIB) | We already use convbin/str2str; `rnx2rtkp` is the planned engine of the CORS quick-start/cross-check (docs/cors_position.md). The `demo5` fork is the one the community uses for low-cost receivers. |
| **rtklibexplorer blog** (https://rtklibexplorer.wordpress.com/) | Practical settings for F9P-class receivers (fix-and-hold, ambiguity resolution thresholds, short baselines). Read before tuning the CORS RTK run. |
| **BNC - BKG Ntrip Client** (https://igs.bkg.bund.de/ntrip/bnc) | Reference NTRIP client (multi-stream, sourcetable, RTCM decoding, can also run PPP). Good for independent comparison and for how a client should handle sourcetables/VRS (GGA). |
| **ntripstreams** (https://github.com/stenseng/ntripstreams) | Python NTRIP client/caster: reference for the "test connection (sourcetable)" step of the CORS accounts. |
| **gLAB** (https://gage.upc.es/gLAB/) | Independent PPP engine (SP3, ANTEX, SINEX). Option for a second opinion on PRIDE-PPPAR results. |
| **pygnsslab** (https://github.com/PyGnssLab/pygnsslab) | Python PPP and PPP-AR engines + RINEX tools; possible cross-check of the PRIDE result. |
| **Ginan** (https://github.com/GeoscienceAustralia/ginan) | Geoscience Australia PPP/PPP-AR and products software; third independent engine, heavy. |
| **Anubis** (https://gnutsoftware.com/software/anubis) | RINEX quality checking (multipath, cycle slips, completeness); candidate for a pre-flight quality gate on the survey RINEX and for the АГКК чл.57 submissions. |
| **RNXCMP / Hatanaka** (https://terras.gsi.go.jp/ja/crx2rnx.html) | Needed if RINEX is submitted to АГКК/EPN compressed (.crx). |
| **GFZRNX** (GFZ, proprietary but free) | RINEX editing/splicing/quality; alternative to our own merge for RINEX submissions. |
| **GeoRust RINEX / SP3 / SINEX** (https://github.com/georust/rinex) | Parsers if we ever need to read SINEX (official station coordinates/velocities) or SP3 programmatically. |
| **Navipedia (ESA)** (https://gssc.esa.int/navipedia/index.php/Main_Page) | Reference for models, frames and PPP/RTK algorithms. |
| **Kalmix GNSS Handbook** (https://www.kalmixtech.com/blogs/blog/tagged/gnss-handbook) | Short notes on RTCM, NTRIP, NMEA and coordinate systems. |
| **GNSS Data Processing books (UPC/gAGE)** (https://gage.upc.edu/en/learning-materials/library/gnss-books) | Theory behind PPP, ambiguity resolution, ionosphere/troposphere. |
| **RENAG** (https://renag.resif.fr/en/) | Example of a public u-blox-based permanent network with 1 s archive: shows that F9P-class stations can run a national-grade network (useful as a data-quality yardstick). |
| **gnss_lib_py** (https://gnss-lib-py.readthedocs.io) | Python parsing/visualisation; possible helper for plots/time series in reports. |

## Not relevant (reviewed, skipped)

Android/iOS apps, smartphone datasets and papers, jamming/spoofing papers, software-defined
receivers (GNSS-SDR, FGI-GSRx), factor-graph/INS fusion projects, signal simulators, satellite
launch lists.

## Other sources already used by the project

- EPN station SOFI00BGR (https://epncb.oma.be/_networkdata/siteinfo4onestation.php?station=SOFI00BGR):
  provisional velocity proxy (`addons/geomaxima_geodesy/sofi_velocity_etrf2000.json`) and the
  validation target of Part 11a (the page returned HTTP 403 to automated fetches, copy data by hand).
- PRIDE-PPPAR (Wuhan University) and its products (igs.gnsswhu.cn): see docs/survey_service.md.
- АГКК РД-02-20-25 / РД-02-20-12 / Наредба 2/2010: see CLAUDE.md section 3.
