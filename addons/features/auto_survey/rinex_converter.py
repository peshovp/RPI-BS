"""
RINEX Converter for Raw GNSS Data
==================================

Converts UBX/RTCM logs to RINEX format using convbin
"""

import subprocess
import logging
import re
from pathlib import Path
from typing import List, Optional, Tuple
from datetime import datetime, timezone
import platform
import shutil

logger = logging.getLogger(__name__)

# Always RINEX 3.04: 3.03+ band numbering (BeiDou B1I = band 2) is what the
# PRIDE-PPPAR frequency selection (pride_pppar_processor.py) assumes; its
# RINEX < 3.03 remap is only a safety net. 3.04 is also this convbin's
# default, but relying on a default is how "-f 2" slipped in (below).
RINEX_VERSION = "3.04"

# convbin -r format by log file extension. RTKBase names its raw logs
# "<name>.<receiver_format>" (run_cast.sh out_file), so the extension IS the
# format settings.conf configured.
_FORMAT_BY_SUFFIX = {'.ubx': 'ubx', '.rtcm3': 'rtcm3', '.rtcm': 'rtcm3',
                     '.sbf': 'sbf', '.unicore': 'unicore'}

# RTKBase log file names start with the logging start time:
# file_name='%Y-%m-%d_%h-%M-%S_GNSS-1' -> 2026-09-29_16-36-33_GNSS-1.rtcm3
_LOG_NAME_TIME_RE = re.compile(r'(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})')


def rtcm_time_reference(raw_file: Path) -> Tuple[datetime, str]:
    """
    Approximate UTC time of an RTCM3 log, for convbin's -tr.

    RTCM3 MSM messages carry only a time of week. Without -tr, RTKLIB
    resolves the week against the CURRENT system time - correct for a log
    converted within ~3.5 days, but a log converted later (a frozen final
    window reprocessed days afterwards, a RAP comparison run) can land in
    the wrong GPS week. The log's start time from its RTKBase file name is
    used; the file's modification time (the last write) is the fallback.

    Returns (time, source) with source 'file name' or 'mtime'.
    """
    m = _LOG_NAME_TIME_RE.search(raw_file.name)
    if m:
        try:
            return datetime(*(int(g) for g in m.groups())), 'file name'
        except ValueError:
            pass
    mtime = datetime.fromtimestamp(raw_file.stat().st_mtime, tz=timezone.utc).replace(tzinfo=None)
    return mtime, 'mtime'


def _convbin_time(flag: str, t: datetime) -> List[str]:
    # convbin takes "y/m/d h:m:s" as two arguments
    return [flag, t.strftime('%Y/%m/%d'), t.strftime('%H:%M:%S')]


def build_convbin_args(convbin: Path, raw_file: Path, output_dir: Path, receiver_format: str,
                       marker_name: Optional[str] = None,
                       time_start: Optional[datetime] = None,
                       time_end: Optional[datetime] = None) -> List[str]:
    """
    convbin argument list for one raw log.

    - NO frequency limit. The former "-f 2" (commented "Force overwrite")
      is convbin's number-of-frequencies option: RTKLIB v2.5.0 turns -f N
      into a bitmask over the per-system band index from code2idx()
      (default N=6: indices 0-5, every band). -f 2 kept only indices 0-1:
      G L1+L2, E E1+E5b (E5a is index 2), C B1I+B2I (B3I is index 3) - on a
      UM980 that forces exactly the degraded E17/C27 pairs. A ZED-F9P
      tracks only two bands per constellation, so its output is unchanged.
      convbin overwrites existing output by default.
      Verified for the shipped binary (tools/bin/RTKLIB-2.5.0, built from
      rtklibexplorer/RTKLIB v2.5.0): its DWARF gives NFREQ=4 (ssat_t.vsat[4])
      and NFREQ+NEXOBS=7 (obsd_t.P[7]), so NEXOBS=3. In RTCM3 MSM decoding
      (rtcm3.c sigindex) each band's highest-priority code takes its main
      slot and every other signal takes one of 3 extended slots per
      satellite; the RINEX writer reads all 7. For UM980 MSM7 that keeps
      every band (G 1/2/5, E 1/5/7/6, C 2/7/6/5/1); only a satellite with
      more than 3 surplus codes would lose one (e.g. a second B1C code).

    - No -mask/-nomask/-y: every signal and constellation is kept; the
      PRIDE-PPPAR frequency selection decides what to use.
    - RINEX 3.04 enforced (-v).
    - rtcm3: -tr from rtcm_time_reference() (week resolution, see there).
    - Optional time window -ts/-te (UTC), e.g. a frozen survey window;
      unused (whole file) by default.
    """
    args = [str(convbin), "-r", receiver_format, "-v", RINEX_VERSION, "-d", str(output_dir)]
    if marker_name:
        args += ["-hm", marker_name]
    if receiver_format == 'rtcm3':
        tr, source = rtcm_time_reference(raw_file)
        args += _convbin_time("-tr", tr)
        logger.info(f"convbin: RTCM3 time reference {tr:%Y-%m-%d %H:%M:%S} UTC (from the log's {source})")
    if time_start:
        args += _convbin_time("-ts", time_start)
    if time_end:
        args += _convbin_time("-te", time_end)
    args.append(str(raw_file))
    return args


def receiver_format_for(raw_file: Path) -> str:
    fmt = _FORMAT_BY_SUFFIX.get(raw_file.suffix.lower())
    if fmt is None:
        logger.warning(f"Unknown raw log extension '{raw_file.suffix}' ({raw_file.name}) - assuming ubx")
        return 'ubx'
    return fmt


def find_rtklib_tool(tool_name: str) -> Optional[Path]:
    """
    Auto-discover RTKLIB tool location
    
    Args:
        tool_name: Name of the tool (convbin, rnx2rtkp, etc.)
        
    Returns:
        Path to tool or None if not found
    """
    # Try 'which' command first (finds tools in PATH)
    tool_path = shutil.which(tool_name)
    if tool_path:
        logger.info(f"Found {tool_name} at {tool_path} (via PATH)")
        return Path(tool_path)
    
    # Get system architecture for RTKBase binaries
    arch = platform.machine()  # e.g., 'armv7l', 'aarch64', 'x86_64'
    
    search_paths = [
        Path("/usr/local/bin") / tool_name,
        Path("/usr/bin") / tool_name,
        Path.home() / "RTKLIB" / tool_name,
        Path.home() / "rtkbase" / "tools" / "bin" / "RTKLIB-2.5.0" / arch / tool_name,
        Path.home() / "rtkbase" / "tools" / "bin" / "RTKLIB-2.5.0" / "armv7l" / tool_name,
        Path.home() / "rtkbase" / "tools" / "bin" / "RTKLIB-2.5.0" / "aarch64" / tool_name,
    ]
    
    for path in search_paths:
        if path.exists() and path.is_file():
            logger.info(f"Found {tool_name} at {path}")
            return path
    
    logger.error(f"Could not find {tool_name} in any of: {search_paths}")
    return None


class RINEXConverter:
    """Convert raw GNSS data to RINEX using RTKLIB convbin"""
    
    def __init__(self, convbin_path: Optional[str] = None):
        """
        Args:
            convbin_path: Path to RTKLIB convbin executable (auto-detected if None)
        """
        if convbin_path is None:
            convbin = find_rtklib_tool("convbin")
            if convbin is None:
                raise FileNotFoundError("convbin not found. Please install RTKLIB.")
            self.convbin = convbin
        else:
            self.convbin = Path(convbin_path)
            if not self.convbin.exists():
                raise FileNotFoundError(f"convbin not found at {convbin_path}")
    
    def convert_to_rinex(self, 
                        input_file: Path, 
                        output_dir: Optional[Path] = None,
                        receiver_type: str = "ubx") -> Optional[Path]:
        """
        Convert raw GNSS log to RINEX observation file
        
        Args:
            input_file: Path to raw data file (.ubx, .rtcm3, .log)
            output_dir: Output directory (default: same as input)
            receiver_type: Receiver format (ubx, rtcm3, etc.)
            
        Returns:
            Path to generated RINEX .obs file or None on failure
        """
        if not input_file.exists():
            logger.error(f"Input file not found: {input_file}")
            return None
        
        # Determine output directory
        if output_dir is None:
            output_dir = input_file.parent
        else:
            output_dir = Path(output_dir)
            output_dir.mkdir(parents=True, exist_ok=True)
        
        # Output file will be auto-named by convbin based on input
        # Format: XXXX_DDDH.YYo where DDD=day-of-year, H=hour, YY=year
        
        try:
            # Run convbin
            # By default convbin generates both .obs and .nav files
            # No need for -o or -n flags
            cmd = build_convbin_args(self.convbin, input_file, output_dir, receiver_type)
            
            logger.info(f"Converting {input_file.name} to RINEX...")
            logger.debug(f"Command: {' '.join(cmd)}")
            
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=300  # 5 minute timeout
            )
            
            if result.returncode != 0:
                logger.error(f"convbin failed: {result.stderr}")
                return None
            
            # Find the generated RINEX file
            # convbin creates files like: XXXX_DDDH.YYo
            rinex_files = list(output_dir.glob("*.obs")) + \
                         list(output_dir.glob("*.[0-9][0-9]o"))
            
            if not rinex_files:
                logger.error("No RINEX file generated")
                logger.debug(f"convbin output: {result.stdout}")
                return None
            
            # Get the newest RINEX file
            rinex_file = max(rinex_files, key=lambda p: p.stat().st_mtime)
            
            logger.info(f"✓ Created RINEX: {rinex_file.name}")
            return rinex_file
            
        except subprocess.TimeoutExpired:
            logger.error("convbin timeout (>5 minutes)")
            return None
        except Exception as e:
            logger.error(f"Conversion failed: {e}", exc_info=True)
            return None
    
    def convert_raw_to_rinex_obs(self,
                                 raw_file: Path,
                                 output_dir: Optional[Path] = None,
                                 marker_name: str = "BASE",
                                 time_start: Optional[datetime] = None,
                                 time_end: Optional[datetime] = None) -> Optional[Tuple[Path, Path]]:
        """
        Convert raw data to RINEX observation and navigation files

        Args:
            raw_file: Raw GNSS data file
            output_dir: Output directory
            marker_name: RINEX marker name (station ID). pdp3.sh derives its
                4-char site code from this field; left unset, convbin writes
                an empty/invalid MARKER NAME and PRIDE-PPPAR fails with
                "error: site name not found in command-line or observation
                file" (confirmed live).
            time_start, time_end: optional UTC window (convbin -ts/-te) -
                only data inside it is converted. None = whole file.

        Returns:
            Tuple of (obs_file, nav_file) or None on failure
        """
        if output_dir is None:
            output_dir = raw_file.parent / "rinex"

        output_dir = Path(output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)

        receiver_type = receiver_format_for(raw_file)

        try:
            # convbin writes both .obs and .nav without explicit flags
            cmd = build_convbin_args(self.convbin, raw_file, output_dir, receiver_type,
                                     marker_name=marker_name,
                                     time_start=time_start, time_end=time_end)

            logger.info(f"Converting to RINEX {RINEX_VERSION} obs+nav: {raw_file.name}"
                        + (f" (window {time_start} .. {time_end} UTC)" if time_start or time_end else ""))
            logger.info(f"convbin command: {' '.join(cmd)}")
            
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
            
            if result.returncode != 0:
                logger.warning(f"convbin warning: {result.stderr}")
                # Continue - may still have output files
            
            # Find generated files
            obs_files = list(output_dir.glob("*.obs")) + list(output_dir.glob("*.[0-9][0-9]o"))
            nav_files = list(output_dir.glob("*.nav")) + list(output_dir.glob("*.[0-9][0-9]n"))
            
            if not obs_files:
                logger.error("No observation file generated")
                return None
            
            obs_file = max(obs_files, key=lambda p: p.stat().st_mtime)
            nav_file = max(nav_files, key=lambda p: p.stat().st_mtime) if nav_files else None
            
            logger.info(f"✓ OBS: {obs_file.name}")
            if nav_file:
                logger.info(f"✓ NAV: {nav_file.name}")
            
            return (obs_file, nav_file)
            
        except Exception as e:
            logger.error(f"RINEX conversion failed: {e}", exc_info=True)
            return None
