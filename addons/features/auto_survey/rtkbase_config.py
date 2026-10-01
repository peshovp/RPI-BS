"""
RTKBase Configuration Parser
============================

Auto-discovery and parsing of RTKBase settings.conf
"""

import configparser
import logging
import os
import zipfile
from datetime import datetime
from pathlib import Path
from typing import List, Optional, Dict, Tuple

from .rinex_converter import parse_log_start_time, _FORMAT_BY_SUFFIX

logger = logging.getLogger(__name__)

# Raw log extensions get_data_files_since() recognizes, both as plain
# files in data_dir and as members inside data_dir's *.zip archives - see
# rinex_converter._FORMAT_BY_SUFFIX (the authoritative list of extensions
# convbin/receiver_format_for() actually knows how to convert; kept as one
# source of truth rather than a second hardcoded list here).
_RAW_LOG_SUFFIXES = tuple(s.lstrip('.') for s in _FORMAT_BY_SUFFIX.keys())


class RTKBaseConfig:
    """Parse and provide RTKBase configuration"""
    
    def __init__(self, settings_file: str = None):
        """
        Args:
            settings_file: Path to RTKBase settings.conf
        """
        if settings_file is None:
            # Resolve rtkbase root the same way web_app/server.py does: relative
            # to this file's location, not $HOME (this may run as root via systemd).
            _rtkbase_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../"))
            settings_file = os.path.join(_rtkbase_root, "settings.conf")
        self.settings_file = Path(settings_file)
        self.config = configparser.ConfigParser()
        
        if not self.settings_file.exists():
            raise FileNotFoundError(f"RTKBase settings not found: {settings_file}")
        
        self.config.read(self.settings_file)
        self._discover_paths()
    
    def _discover_paths(self):
        """Auto-discover RTKBase directory structure"""
        # RTKBase root is parent of settings.conf
        self.rtkbase_root = self.settings_file.parent
        
        # Standard RTKBase paths
        self.logs_dir = self.rtkbase_root / "logs"
        self.data_dir = self.rtkbase_root / "data"
        self.archives_dir = self.rtkbase_root / "archives"
        
        logger.info(f"RTKBase root: {self.rtkbase_root}")
        logger.info(f"Logs dir: {self.logs_dir}")
    
    def get_position(self) -> Optional[Tuple[float, float, float]]:
        """
        Get current configured position (lat, lon, height)
        
        Returns:
            (lat, lon, height) tuple or None
        """
        try:
            pos_str = self.config.get('main', 'position', fallback=None)
            if not pos_str:
                return None
            
            # Format: 'lat lon height' or 'lat,lon,height'
            pos_str = pos_str.strip("'\"")
            parts = pos_str.replace(',', ' ').split()
            
            if len(parts) >= 3:
                lat = float(parts[0])
                lon = float(parts[1])
                height = float(parts[2])
                return (lat, lon, height)
        except Exception as e:
            logger.warning(f"Failed to parse position: {e}")
        
        return None
    
    def get_receiver_info(self) -> Dict[str, str]:
        """Get receiver information"""
        return {
            'model': self.config.get('main', 'receiver', fallback='Unknown'),
            'format': self.config.get('main', 'receiver_format', fallback='ubx'),
            'firmware': self.config.get('main', 'receiver_firmware', fallback=''),
            'antenna': self.config.get('main', 'antenna_info', fallback=''),
        }
    
    def get_com_port(self) -> Tuple[str, str]:
        """
        Get COM port and settings
        
        Returns:
            (port, settings) e.g. ('ttyGNSS', '115200:8:n:1')
        """
        port = self.config.get('main', 'com_port', fallback='ttyACM0')
        settings = self.config.get('main', 'com_port_settings', fallback='115200:8:n:1')
        return (port, settings)
    
    def find_latest_log(self, pattern: str = "str2str_*.log") -> Optional[Path]:
        """
        Find the most recent log file matching pattern
        
        Args:
            pattern: Glob pattern for log files
            
        Returns:
            Path to latest log or None
        """
        if not self.logs_dir.exists():
            logger.warning(f"Logs directory not found: {self.logs_dir}")
            return None
        
        log_files = list(self.logs_dir.glob(pattern))
        
        if not log_files:
            logger.warning(f"No logs matching '{pattern}' in {self.logs_dir}")
            return None
        
        # Sort by modification time, newest first
        latest = max(log_files, key=lambda p: p.stat().st_mtime)
        logger.info(f"Latest log: {latest}")
        return latest
    
    def get_data_file(self) -> Optional[Path]:
        """
        Get the current GNSS data file being written
        
        Checks in order:
        1. data/ directory for active files
        2. logs/ directory for str2str_file logs
        3. Latest str2str_tcp log
        
        Returns:
            Path to data file or None
        """
        # Check data directory first. str2str_file names the raw log
        # "<file_name>.<receiver_format>" (run_cast.sh out_file), so the
        # configured format's extension is looked for first; the other raw
        # formats the converter handles (rinex_converter._FORMAT_BY_SUFFIX)
        # are still recognised. Previously only .ubx/.rtcm3 were, so a
        # station logging "sbf" or "unicore" silently fell back to a
        # str2str log file.
        if self.data_dir.exists():
            configured = self.config.get('main', 'receiver_format', fallback='').strip("'\" ")
            exts = [configured] if configured else []
            exts += [e for e in ('ubx', 'rtcm3', 'sbf', 'unicore') if e != configured]
            for ext in exts:
                data_files = list(self.data_dir.glob(f"*.{ext}"))
                if data_files:
                    return max(data_files, key=lambda p: p.stat().st_mtime)
        
        # Check for file service logs
        file_log = self.find_latest_log("str2str_file_*.log")
        if file_log:
            return file_log
        
        # Fallback to TCP log (may contain data)
        tcp_log = self.find_latest_log("str2str_tcp_*.log")
        return tcp_log

    def get_data_files_since(self, start_time: datetime, extract_dir: Optional[Path] = None) -> List[Path]:
        """
        Every raw GNSS log segment overlapping [start_time, now] - unlike
        get_data_file() (latest file only), this follows a survey/slot
        window across any str2str raw-log ROTATION that happened inside
        it (file_rotate_time, typically '24' = UTC midnight: str2str
        starts a brand-new file at the rotation moment and leaves the
        previous one closed in data_dir), and across archive_and_clean.sh
        having since ZIPPED an older segment into one of data_dir's
        *.zip archives (it runs daily at 04:00, folding in any raw file
        over 60 minutes old - so by the time a multi-hour-old survey's
        interim slot runs, yesterday's segment is often already zipped,
        not a plain file).

        Without this, a slot running after a rotation only ever saw the
        file get_data_file() happened to return (whichever one is
        NEWEST) - silently processing only the data since the rotation,
        not the whole [survey_start, now] window the slot is supposed to
        cover.

        A file/zip member is considered part of the window if its parsed
        start time (parse_log_start_time() - the moment str2str began
        writing it) is itself before `now` (it could only have started
        once) AND its start time is not so far after start_time that it
        couldn't contain any data from the window - in practice: keep
        every segment whose [start, end) range overlaps [start_time, now)
        - a segment's END is the NEXT segment's start (str2str's
        rotation is back-to-back, file_overlap_time defaults to '0'), or
        "now" for whichever segment is the newest. The caller's convbin
        -ts/-te (time_start passed through from _run_ppp_ar_interim()/
        _finalize_survey()) still trims any data each kept segment has
        outside [start_time, now] - this method only decides WHICH
        segments to hand to convbin at all, same as get_data_file()
        already relies on -ts/-te to trim the single file it returns. A
        file whose name doesn't match the expected pattern
        (parse_log_start_time() returns None) is always included (fail
        open - better to feed convbin a segment it ends up not needing
        than to silently drop part of the window).

        Args:
            start_time: UTC start of the window (survey start, or the
                relevant interim slot's own start - see
                survey_controller.py's callers).
            extract_dir: where to extract matching members found inside a
                *.zip archive. Required only if any zip actually
                contains a matching member; the caller owns cleaning this
                up (it is NOT a temp dir created/removed here, since the
                caller's own per-attempt work_dir already provides one -
                see _run_ppp_ar()'s isolated work_dir scheme).

        Returns:
            List of raw file paths (plain files and/or zip-extracted
            temp copies), UNSORTED - see
            rinex_converter.convert_raw_files_to_rinex_obs(), which sorts
            them chronologically itself. Empty list if nothing overlaps
            (caller should treat this the same as get_data_file()
            returning None).
        """
        if not self.data_dir.exists():
            logger.warning(f"get_data_files_since: data_dir does not exist: {self.data_dir}")
            return []

        now = datetime.utcnow()

        # First pass: every CANDIDATE segment (plain file or zip member)
        # with its parsed start time, unfiltered by the window - needed
        # so each one's END can be derived from the NEXT segment's start
        # across the whole set, not just within whatever subset happens
        # to pass a per-file filter.
        # candidate: (seg_start_or_None, is_plain_file, path_or_(zip_path, member_name))
        candidates = []
        for suffix in _RAW_LOG_SUFFIXES:
            for f in self.data_dir.glob(f"*.{suffix}"):
                candidates.append((parse_log_start_time(f), True, f))

        for zip_path in self.data_dir.glob("*.zip"):
            try:
                with zipfile.ZipFile(zip_path) as zf:
                    for member in zf.namelist():
                        member_path = Path(member)
                        if member_path.suffix.lstrip('.').lower() not in _RAW_LOG_SUFFIXES:
                            continue
                        candidates.append((parse_log_start_time(member_path), False, (zip_path, member)))
            except zipfile.BadZipFile as e:
                logger.warning(f"get_data_files_since: could not read {zip_path} as a zip: {e}")

        # Sort by start time (unparseable names sort last - their actual
        # start is unknown, so they cannot anchor another segment's end;
        # they are always kept regardless, per the fail-open rule above).
        dated = sorted((c for c in candidates if c[0] is not None), key=lambda c: c[0])
        undated = [c for c in candidates if c[0] is None]

        kept = []
        for i, (seg_start, is_plain, ref) in enumerate(dated):
            seg_end = dated[i + 1][0] if i + 1 < len(dated) else now
            if seg_end >= start_time and seg_start <= now:
                kept.append((is_plain, ref))
        kept += [(is_plain, ref) for _seg_start, is_plain, ref in undated]

        found: List[Path] = []
        for is_plain, ref in kept:
            if is_plain:
                found.append(ref)
                continue
            zip_path, member = ref
            if extract_dir is None:
                logger.warning(f"get_data_files_since: {zip_path.name} contains a matching "
                               f"raw segment ({member}) but no extract_dir was given - "
                               f"skipping it (window may be incomplete)")
                continue
            extract_dir = Path(extract_dir)
            extract_dir.mkdir(parents=True, exist_ok=True)
            extracted_path = extract_dir / Path(member).name
            try:
                with zipfile.ZipFile(zip_path) as zf, zf.open(member) as src, open(extracted_path, 'wb') as dst:
                    dst.write(src.read())
                logger.info(f"get_data_files_since: extracted {member} from "
                           f"{zip_path.name} -> {extracted_path}")
                found.append(extracted_path)
            except Exception as e:
                logger.warning(f"get_data_files_since: failed to extract {member} from "
                               f"{zip_path.name}: {e}")

        if not found:
            logger.warning(f"get_data_files_since: no raw segments found overlapping "
                           f"[{start_time.isoformat()}, now] in {self.data_dir}")
        else:
            logger.info(f"get_data_files_since({start_time.isoformat()}): "
                       f"{len(found)} segment(s): {[f.name for f in found]}")
        return found

    def update_position(self, lat: float, lon: float, height: float) -> bool:
        """
        Update position in settings.conf
        
        CRITICAL: RTKBase expects position format with single quotes:
        position = '42.68045168 26.30807124 104.425'
        
        ConfigParser.write() removes the quotes, so we do direct file editing!
        
        Args:
            lat: Latitude (degrees)
            lon: Longitude (degrees)
            height: Height (meters, WGS84 ellipsoidal - NOT MSL/orthometric.
                    This value is embedded into RTCM 1005/1006 via str2str -p,
                    which requires ellipsoidal height for correct ARP coordinates.)
            
        Returns:
            True if updated successfully
        """
        try:
            logger.info("=" * 70)
            logger.info("UPDATE_POSITION CALLED")
            logger.info(f"  Input: lat={lat:.8f}, lon={lon:.8f}, height={height:.3f}")
            logger.info(f"  Settings file: {self.settings_file}")
            
            # Format position string exactly as RTKBase expects
            position_value = f"{lat:.8f} {lon:.8f} {height:.3f}"
            logger.info(f"  Formatted value: '{position_value}'")
            
            # Check file exists and is writable
            import os
            if not os.path.exists(self.settings_file):
                logger.error(f"  ✗ Settings file does not exist!")
                return False
            
            if not os.access(self.settings_file, os.W_OK):
                logger.error(f"  ✗ Settings file is not writable!")
                return False
            
            logger.info(f"  ✓ File exists and is writable")
            
            # Read entire file
            logger.info(f"  Reading file...")
            with open(self.settings_file, 'r') as f:
                lines = f.readlines()
            logger.info(f"  ✓ Read {len(lines)} lines")
            
            # Find position line
            logger.info(f"  Searching for 'position' line...")
            updated = False
            old_value = None
            for i, line in enumerate(lines):
                if line.strip().startswith('position'):
                    old_value = line.strip()
                    logger.info(f"  Found at line {i+1}: {old_value}")
                    # Replace with proper RTKBase format (with single quotes)
                    lines[i] = f"position='{position_value}'\n"
                    updated = True
                    logger.info(f"  New line: {lines[i].strip()}")
                    break
            
            if not updated:
                logger.warning("  position= line not found; inserting into [main] section")
                # Try to find [main] section boundaries
                main_start = None
                main_end = None
                for i, line in enumerate(lines):
                    if line.strip().lower() == '[main]':
                        main_start = i
                        # find next section start
                        for j in range(i+1, len(lines)):
                            if lines[j].strip().startswith('[') and lines[j].strip().endswith(']'):
                                main_end = j
                                break
                        break
                insert_line = f"position='{position_value}'\n"
                if main_start is not None:
                    # Insert before next section or at end
                    insert_index = main_end if main_end is not None else len(lines)
                    lines.insert(insert_index, insert_line)
                    logger.info(f"  Inserted position at line {insert_index+1} within [main]")
                else:
                    # No [main] section; create one at top
                    lines = ["[main]\n", insert_line] + lines
                    logger.info("  Created [main] section and inserted position at file start")
            
            # Write back entire file ATOMICALLY - a direct in-place write
            # (open(path, 'w') truncates immediately, before new content is
            # written) leaves a real window where a concurrent reader (e.g.
            # run_cast.sh's "source settings.conf" during a service restart
            # triggered by this same update) could see a truncated/partial
            # file with the position line missing its value entirely -
            # confirmed as the actual root cause of a live bug this session
            # (str2str launched with "-p" immediately followed by the next
            # flag, no lat/lon/height, because settings.conf was caught
            # mid-write). Writing to a temp file in the same directory then
            # os.replace()-ing it onto the real path is a single atomic
            # filesystem operation - any concurrent reader always sees
            # either the complete old file or the complete new file, never
            # a partial one, regardless of timing.
            logger.info(f"  Writing updated file (atomic)...")
            tmp_path = f"{self.settings_file}.tmp"
            with open(tmp_path, 'w') as f:
                f.writelines(lines)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp_path, self.settings_file)
            logger.info(f"  ✓ File written and flushed to disk")
            
            # Verify the change
            logger.info(f"  Verifying change...")
            with open(self.settings_file, 'r') as f:
                for line in f:
                    if line.strip().startswith('position'):
                        logger.info(f"  Verified: {line.strip()}")
                        if position_value in line:
                            logger.info(f"  ✓ VERIFICATION PASSED - coordinates updated!")
                        else:
                            logger.error(f"  ✗ VERIFICATION FAILED - coordinates NOT updated!")
                            logger.error(f"    Expected: '{position_value}'")
                            logger.error(f"    Found: {line.strip()}")
                            return False
                        break
            
            # Reload config to ensure we have latest values
            self.config.read(self.settings_file)
            
            # Touch file to trigger RTKBase inotify reload
            import os
            os.utime(self.settings_file, None)
            logger.info(f"  ✓ File touched for inotify")
            
            logger.info("=" * 70)
            logger.info("✓ UPDATE_POSITION COMPLETED SUCCESSFULLY")
            logger.info(f"  Old: {old_value}")
            logger.info(f"  New: position = '{position_value}'")
            logger.info("=" * 70)
            
            return True
            
        except Exception as e:
            logger.error(f"✗ UPDATE_POSITION FAILED: {e}")
            import traceback
            logger.error(traceback.format_exc())
            return False
