"""
SPP Position Processor
======================

Process RINEX files with RTKLIB rnx2rtkp for SPP positioning
"""

import subprocess
import logging
from pathlib import Path
from typing import Optional, List, Dict, Tuple
import re
import platform
import shutil

logger = logging.getLogger(__name__)


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


class SPPProcessor:
    """Process RINEX for Single Point Positioning using rnx2rtkp"""
    
    def __init__(self, rnx2rtkp_path: Optional[str] = None):
        """
        Args:
            rnx2rtkp_path: Path to RTKLIB rnx2rtkp executable (auto-detected if None)
        """
        if rnx2rtkp_path is None:
            rnx2rtkp = find_rtklib_tool("rnx2rtkp")
            if rnx2rtkp is None:
                raise FileNotFoundError("rnx2rtkp not found. Please install RTKLIB.")
            self.rnx2rtkp = rnx2rtkp
        else:
            self.rnx2rtkp = Path(rnx2rtkp_path)
            if not self.rnx2rtkp.exists():
                raise FileNotFoundError(f"rnx2rtkp not found at {rnx2rtkp_path}")
    
    def process_spp(self,
                   obs_file: Path,
                   nav_file: Optional[Path] = None,
                   output_file: Optional[Path] = None) -> Optional[Path]:
        """
        Process RINEX observation for SPP
        
        Args:
            obs_file: RINEX observation file
            nav_file: RINEX navigation file (optional, auto-detected)
            output_file: Output position file (default: obs_file with .pos extension)
            
        Returns:
            Path to position file (.pos) or None on failure
        """
        if not obs_file.exists():
            logger.error(f"Observation file not found: {obs_file}")
            return None
        
        # Auto-detect nav file if not provided
        if nav_file is None:
            # Look for .nav or .[YY]n in same directory
            obs_dir = obs_file.parent
            nav_files = list(obs_dir.glob("*.nav")) + \
                       list(obs_dir.glob("*.[0-9][0-9]n"))
            
            if nav_files:
                nav_file = max(nav_files, key=lambda p: p.stat().st_mtime)
                logger.info(f"Auto-detected nav file: {nav_file.name}")
        
        if nav_file and not nav_file.exists():
            logger.warning(f"Nav file not found: {nav_file}")
            nav_file = None
        
        # Determine output file
        if output_file is None:
            output_file = obs_file.with_suffix('.pos')
        else:
            output_file = Path(output_file)
        
        try:
            # Build rnx2rtkp command for SPP
            # -p 0: SPP (single point positioning)
            # -m 15: Elevation mask 15 degrees
            # -f 2: Output format (lat/lon/height)
            # -o: Output file
            cmd = [
                str(self.rnx2rtkp),
                "-p", "0",  # SPP mode
                "-m", "15",  # Elevation mask
                "-f", "2",  # Output format: lat/lon/height
                "-o", str(output_file),
                str(obs_file)
            ]
            
            # Add nav file if available (as additional argument, not with -n flag)
            if nav_file:
                cmd.append(str(nav_file))
            
            logger.info(f"Processing SPP: {obs_file.name}")
            logger.debug(f"Command: {' '.join(cmd)}")
            
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=600  # 10 minute timeout
            )
            
            if result.returncode != 0:
                logger.error(f"rnx2rtkp failed: {result.stderr}")
                return None
            
            if not output_file.exists():
                logger.error("No position file generated")
                return None
            
            # Check file has data
            file_size = output_file.stat().st_size
            if file_size < 100:  # Less than 100 bytes likely empty
                logger.error(f"Position file too small ({file_size} bytes)")
                return None
            
            logger.info(f"✓ SPP position file: {output_file.name} ({file_size} bytes)")
            return output_file
            
        except subprocess.TimeoutExpired:
            logger.error("rnx2rtkp timeout (>10 minutes)")
            return None
        except Exception as e:
            logger.error(f"SPP processing failed: {e}", exc_info=True)
            return None
    
    def parse_position_file(self, pos_file: Path) -> List[Dict]:
        """
        Parse RTKLIB position file (.pos)
        
        Args:
            pos_file: Path to .pos file
            
        Returns:
            List of position records with keys:
                - datetime: datetime object
                - lat, lon, height: position (degrees, meters)
                - Q: quality flag (1=FIX, 2=FLOAT, 5=SINGLE)
                - ns: number of satellites
                - sdn, sde, sdu: position stddev (m)
                - sdne, sdeu, sdun: position correlation
                - age: differential age (s)
                - ratio: ambiguity ratio
        """
        if not pos_file.exists():
            logger.error(f"Position file not found: {pos_file}")
            return []
        
        positions = []
        
        try:
            with open(pos_file, 'r') as f:
                for line in f:
                    line = line.strip()
                    
                    # Skip comments and empty lines
                    if not line or line.startswith('%'):
                        continue
                    
                    # Parse position line
                    # Format can be:
                    #   1) YYYY/MM/DD HH:MM:SS.SSS lat lon height Q ns ...
                    #   2) week seconds lat lon height Q ns ... (GPS time)
                    parts = line.split()
                    
                    if len(parts) < 7:  # Minimum: week/date time lat lon height Q ns
                        continue
                    
                    try:
                        # Detect format by checking first field
                        if '/' in parts[0]:
                            # Format 1: Date/time format
                            record = {
                                'date': parts[0],
                                'time': parts[1],
                                'lat': float(parts[2]),
                                'lon': float(parts[3]),
                                'height': float(parts[4]),
                                'Q': int(parts[5]),
                                'ns': int(parts[6]),
                                'sdn': float(parts[7]) if len(parts) > 7 else 0.0,
                                'sde': float(parts[8]) if len(parts) > 8 else 0.0,
                                'sdu': float(parts[9]) if len(parts) > 9 else 0.0,
                            }
                            idx_offset = 0
                        else:
                            # Format 2: GPS week/second format
                            record = {
                                'week': int(parts[0]),
                                'seconds': float(parts[1]),
                                'lat': float(parts[2]),
                                'lon': float(parts[3]),
                                'height': float(parts[4]),
                                'Q': int(parts[5]),
                                'ns': int(parts[6]),
                                'sdn': float(parts[7]) if len(parts) > 7 else 0.0,
                                'sde': float(parts[8]) if len(parts) > 8 else 0.0,
                                'sdu': float(parts[9]) if len(parts) > 9 else 0.0,
                            }
                            idx_offset = 0
                        
                        # Optional fields (same indices for both formats)
                        if len(parts) > 10:
                            record['sdne'] = float(parts[10])
                        if len(parts) > 11:
                            record['sdeu'] = float(parts[11])
                        if len(parts) > 12:
                            record['sdun'] = float(parts[12])
                        if len(parts) > 13:
                            record['age'] = float(parts[13])
                        if len(parts) > 14:
                            record['ratio'] = float(parts[14])
                        
                        positions.append(record)
                        
                    except (ValueError, IndexError) as e:
                        logger.debug(f"Failed to parse line: {line[:50]}... ({e})")
                        continue
            
            logger.info(f"Parsed {len(positions)} positions from {pos_file.name}")
            return positions
            
        except Exception as e:
            logger.error(f"Failed to parse position file: {e}", exc_info=True)
            return []
