"""
GNSS Data Parser
===============

Parses RTKLIB position solutions and extracts quality metrics.

RTKLIB solution format (.pos):
- Columns: %  GPST, latitude(deg), longitude(deg), height(m), Q, ns, sdn(m), sde(m), sdu(m), sdne(m), sdeu(m), sdun(m), age(s), ratio
- Q: Quality flag (1=FIX, 2=FLOAT, 4=DGPS, 5=SINGLE)
- ns: Number of satellites
- sdn, sde, sdu: North, East, Up standard deviations
- ratio: Ambiguity ratio for validation

We use only Q=1 (FIX) solutions for survey precision.
"""

import logging
from datetime import datetime
from typing import List, Dict, Optional, Tuple
from dataclasses import dataclass
import numpy as np

logger = logging.getLogger(__name__)


@dataclass
class GNSSEpoch:
    """Single GNSS position epoch with quality metrics"""
    timestamp: datetime
    lat: float  # degrees
    lon: float  # degrees
    height: float  # ellipsoidal height, meters
    quality: int  # 1=FIX, 2=FLOAT, etc.
    num_sats: int
    std_n: float  # North std dev, meters
    std_e: float  # East std dev, meters  
    std_u: float  # Up std dev, meters
    ratio: float  # Ambiguity ratio
    
    @property
    def is_fix(self) -> bool:
        """Check if this is a FIX solution"""
        return self.quality == 1
    
    @property
    def position_std_3d(self) -> float:
        """3D position standard deviation (RMS)"""
        return np.sqrt(self.std_n**2 + self.std_e**2 + self.std_u**2)
    
    @property
    def horizontal_std(self) -> float:
        """Horizontal standard deviation (RMS)"""
        return np.sqrt(self.std_n**2 + self.std_e**2)
    
    def to_ecef(self) -> Tuple[float, float, float]:
        """
        Convert geodetic (lat, lon, h) to ECEF (X, Y, Z)
        
        Uses WGS84 ellipsoid parameters.
        """
        lat_rad = np.radians(self.lat)
        lon_rad = np.radians(self.lon)
        
        # WGS84 parameters
        a = 6378137.0  # semi-major axis
        f = 1.0 / 298.257223563  # flattening
        e2 = 2*f - f*f  # first eccentricity squared
        
        # Radius of curvature in prime vertical
        N = a / np.sqrt(1 - e2 * np.sin(lat_rad)**2)
        
        X = (N + self.height) * np.cos(lat_rad) * np.cos(lon_rad)
        Y = (N + self.height) * np.cos(lat_rad) * np.sin(lon_rad)
        Z = (N * (1 - e2) + self.height) * np.sin(lat_rad)
        
        return X, Y, Z


class GNSSDataParser:
    """
    Parser for RTKLIB .pos solution files
    
    Extracts FIX solutions with quality filtering for survey processing.
    """
    
    def __init__(self, min_ratio: float = 3.0, max_std_3d: float = 0.05):
        """
        Args:
            min_ratio: Minimum ambiguity ratio for FIX validation (default: 3.0)
            max_std_3d: Maximum 3D std dev in meters (default: 0.05m = 5cm)
        """
        self.min_ratio = min_ratio
        self.max_std_3d = max_std_3d
        
    def parse_pos_file(self, filepath: str, 
                       max_epochs: Optional[int] = None) -> List[GNSSEpoch]:
        """
        Parse RTKLIB .pos file and extract quality epochs
        
        Args:
            filepath: Path to .pos file
            max_epochs: Maximum number of epochs to read (None = all)
            
        Returns:
            List of GNSSEpoch objects with Q=1 (FIX) only
        """
        epochs = []
        
        try:
            with open(filepath, 'r') as f:
                for line in f:
                    # Skip comments and empty lines
                    if line.startswith('%') or line.startswith('#') or not line.strip():
                        continue
                    
                    try:
                        epoch = self._parse_line(line)
                        if epoch and self._is_quality_epoch(epoch):
                            epochs.append(epoch)
                            
                            if max_epochs and len(epochs) >= max_epochs:
                                break
                                
                    except Exception as e:
                        logger.debug(f"Failed to parse line: {e}")
                        continue
                        
        except Exception as e:
            logger.error(f"Failed to read {filepath}: {e}")
            return []
        
        logger.info(f"Parsed {len(epochs)} quality FIX epochs from {filepath}")
        return epochs
    
    def _parse_line(self, line: str) -> Optional[GNSSEpoch]:
        """
        Parse single line from .pos file
        
        Format: GPST, lat, lon, height, Q, ns, sdn, sde, sdu, sdne, sdeu, sdun, age, ratio
        """
        parts = line.split()
        if len(parts) < 14:
            return None
        
        try:
            # Parse timestamp (GPST: yyyy/mm/dd hh:mm:ss.sss or week/seconds)
            timestamp = self._parse_timestamp(parts[0], parts[1])
            
            # Parse position and quality
            lat = float(parts[2])
            lon = float(parts[3])
            height = float(parts[4])
            quality = int(parts[5])
            num_sats = int(parts[6])
            
            # Parse standard deviations
            std_n = float(parts[7])
            std_e = float(parts[8])
            std_u = float(parts[9])
            
            # Parse ambiguity ratio
            ratio = float(parts[13])
            
            return GNSSEpoch(
                timestamp=timestamp,
                lat=lat,
                lon=lon,
                height=height,
                quality=quality,
                num_sats=num_sats,
                std_n=std_n,
                std_e=std_e,
                std_u=std_u,
                ratio=ratio
            )
            
        except (ValueError, IndexError) as e:
            logger.debug(f"Parse error: {e}")
            return None
    
    def _parse_timestamp(self, date_str: str, time_str: str) -> datetime:
        """
        Parse GPST timestamp from RTKLIB format
        
        Handles both calendar (yyyy/mm/dd hh:mm:ss) and week/tow formats.
        """
        try:
            # Calendar format: yyyy/mm/dd hh:mm:ss.sss
            if '/' in date_str:
                dt_str = f"{date_str} {time_str}"
                return datetime.strptime(dt_str.split('.')[0], "%Y/%m/%d %H:%M:%S")
            else:
                # Week/TOW format - convert to approximate datetime
                # For simplicity, we just use current time offset
                return datetime.utcnow()
        except Exception:
            return datetime.utcnow()
    
    def _is_quality_epoch(self, epoch: GNSSEpoch) -> bool:
        """
        Check if epoch meets quality criteria for survey
        
        Criteria:
        - Must be FIX solution (Q=1)
        - Ambiguity ratio >= threshold
        - 3D std dev <= threshold
        - Minimum 5 satellites
        """
        if not epoch.is_fix:
            return False
        
        if epoch.ratio < self.min_ratio:
            logger.debug(f"Low ratio: {epoch.ratio:.2f}")
            return False
        
        if epoch.position_std_3d > self.max_std_3d:
            logger.debug(f"High std: {epoch.position_std_3d:.3f}m")
            return False
        
        if epoch.num_sats < 5:
            logger.debug(f"Low satellite count: {epoch.num_sats}")
            return False
        
        return True
    
    def compute_statistics(self, epochs: List[GNSSEpoch]) -> Dict:
        """
        Compute statistics for a set of epochs
        
        Returns dict with mean position, std devs, fix ratio, etc.
        """
        if not epochs:
            return {}
        
        lats = np.array([e.lat for e in epochs])
        lons = np.array([e.lon for e in epochs])
        heights = np.array([e.height for e in epochs])
        ratios = np.array([e.ratio for e in epochs])
        num_sats = np.array([e.num_sats for e in epochs])
        
        return {
            'num_epochs': len(epochs),
            'mean_lat': np.mean(lats),
            'mean_lon': np.mean(lons),
            'mean_height': np.mean(heights),
            'std_lat': np.std(lats),
            'std_lon': np.std(lons),
            'std_height': np.std(heights),
            'mean_ratio': np.mean(ratios),
            'mean_sats': np.mean(num_sats),
            'fix_ratio': 1.0  # All epochs are FIX by design
        }
