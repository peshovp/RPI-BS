"""
RINEX Converter for Raw GNSS Data
==================================

Converts UBX/RTCM logs to RINEX format using convbin
"""

import subprocess
import logging
from pathlib import Path
from typing import Optional, Tuple
from datetime import datetime
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
            cmd = [
                str(self.convbin),
                "-r", receiver_type,
                "-d", str(output_dir),
                "-f", "2",  # Force overwrite
                str(input_file)
            ]
            
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
                                 marker_name: str = "BASE") -> Optional[Tuple[Path, Path]]:
        """
        Convert raw data to RINEX observation and navigation files
        
        Args:
            raw_file: Raw GNSS data file
            output_dir: Output directory
            marker_name: RINEX marker name (station ID)
            
        Returns:
            Tuple of (obs_file, nav_file) or None on failure
        """
        if output_dir is None:
            output_dir = raw_file.parent / "rinex"
        
        output_dir = Path(output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)
        
        # Determine receiver format from file extension
        suffix = raw_file.suffix.lower()
        if suffix in ['.ubx']:
            receiver_type = 'ubx'
        elif suffix in ['.rtcm3', '.rtcm']:
            receiver_type = 'rtcm3'
        else:
            # Try to detect from content
            receiver_type = 'ubx'  # Default
        
        try:
            # Run convbin for both observation and navigation
            # convbin auto-generates both .obs and .nav without explicit flags
            cmd = [
                str(self.convbin),
                "-r", receiver_type,
                "-d", str(output_dir),
                "-f", "2",  # Force overwrite
                str(raw_file)
            ]
            
            logger.info(f"Converting to RINEX obs+nav: {raw_file.name}")
            logger.debug(f"Command: {' '.join(cmd)}")
            
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
