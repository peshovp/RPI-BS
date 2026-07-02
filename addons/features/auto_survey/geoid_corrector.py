"""
Geoid Corrector
==============

Converts ellipsoidal heights to orthometric heights using geoid models.

RTKBase uses orthometric heights (MSL = Mean Sea Level) for base station coordinates,
but GNSS solutions provide ellipsoidal heights (WGS84). The geoid separation varies
globally from -100m to +100m.

Supports EGM96/EGM2008 .ggf grid files (RTKLIB format).
"""

import logging
import struct
from typing import Optional, Tuple
from dataclasses import dataclass
import numpy as np

logger = logging.getLogger(__name__)


@dataclass
class GeoidModel:
    """Geoid grid model metadata"""
    name: str
    lat_min: float
    lat_max: float
    lon_min: float
    lon_max: float
    dlat: float  # grid spacing in degrees
    dlon: float
    nlat: int  # number of grid points
    nlon: int
    data: np.ndarray  # grid values in meters (shape: nlat x nlon)


class GeoidCorrector:
    """
    Geoid height interpolation from .ggf grid files
    
    Uses bilinear interpolation for smooth height corrections.
    """
    
    def __init__(self, ggf_path: Optional[str] = None):
        """
        Args:
            ggf_path: Path to .ggf geoid grid file (optional)
        """
        self.model: Optional[GeoidModel] = None
        self.last_error: Optional[str] = None
        
        if ggf_path:
            self.load_model(ggf_path)
    
    def load_model(self, ggf_path: str) -> bool:
        """
        Load geoid model from .ggf file
        
        RTKLIB .ggf format:
        - Binary file with header + grid data
        - Header: lat/lon bounds, spacing, grid size
        - Data: float32 geoid heights in meters
        
        Args:
            ggf_path: Path to .ggf file
            
        Returns:
            True if loaded successfully
        """
        self.last_error = None
        try:
            with open(ggf_path, 'rb') as f:
                # Read first line/header as text (RTKLIB .ggf is text header + binary grid)
                header_line = f.readline().decode('ascii', errors='ignore').replace('\x00', ' ').strip()
                import re
                numbers = re.findall(r"[-+]?\d*\.\d+(?:[eE][-+]?\d+)?|[-+]?\d+", header_line)
                if len(numbers) < 6:
                    msg = f"Invalid GGF header: '{header_line}'"
                    logger.error(msg)
                    self.last_error = msg
                    return False
                lat_min, lat_max, lon_min, lon_max, dlat, dlon = map(float, numbers[:6])
                
                # Validate spacing to avoid division by zero
                if dlat <= 0 or dlon <= 0:
                    msg = f"Invalid grid spacing: dlat={dlat}, dlon={dlon}"
                    logger.error(msg)
                    self.last_error = msg
                    return False
                
                # Compute grid dimensions
                nlat = int((lat_max - lat_min) / dlat) + 1
                nlon = int((lon_max - lon_min) / dlon) + 1
                
                if nlat <= 0 or nlon <= 0:
                    msg = f"Invalid grid dimensions: {nlat}x{nlon}"
                    logger.error(msg)
                    self.last_error = msg
                    return False
                
                logger.info(f"Geoid grid: {nlat}x{nlon}, spacing: {dlat}°x{dlon}°")
                
                # Read grid data (float32 values)
                grid_size = nlat * nlon
                data = np.fromfile(f, dtype='<f4', count=grid_size)
                if data.size < grid_size:
                    msg = f"Incomplete grid data: expected {grid_size} floats, got {data.size}"
                    logger.error(msg)
                    self.last_error = msg
                    return False
                data = data.reshape(nlat, nlon)
                
                self.model = GeoidModel(
                    name=ggf_path.split('/')[-1],
                    lat_min=lat_min,
                    lat_max=lat_max,
                    lon_min=lon_min,
                    lon_max=lon_max,
                    dlat=dlat,
                    dlon=dlon,
                    nlat=nlat,
                    nlon=nlon,
                    data=data
                )
                
                logger.info(f"Loaded geoid model: {self.model.name}")
                logger.info(f"Height range: {np.min(data):.2f}m to {np.max(data):.2f}m")
                return True
                
        except Exception as e:
            msg = f"Failed to load geoid model from {ggf_path}: {e}"
            logger.error(msg)
            self.last_error = str(e)
            return False
    
    def get_geoid_height(self, lat: float, lon: float) -> Optional[float]:
        """
        Get geoid height at given position using bilinear interpolation
        
        Args:
            lat: Latitude in degrees
            lon: Longitude in degrees
            
        Returns:
            Geoid height in meters (N), or None if outside grid or no model loaded
        """
        if not self.model:
            logger.warning("No geoid model loaded")
            return None
        
        # Normalize longitude to [0, 360)
        lon = lon % 360
        if lon < 0:
            lon += 360
        
        # Check bounds
        if (lat < self.model.lat_min or lat > self.model.lat_max or
            lon < self.model.lon_min or lon > self.model.lon_max):
            logger.debug(f"Position outside grid bounds: {lat:.6f}, {lon:.6f}")
            return None
        
        # Find grid indices
        ilat = (lat - self.model.lat_min) / self.model.dlat
        ilon = (lon - self.model.lon_min) / self.model.dlon
        
        # Bilinear interpolation
        i0 = int(np.floor(ilat))
        j0 = int(np.floor(ilon))
        i1 = min(i0 + 1, self.model.nlat - 1)
        j1 = min(j0 + 1, self.model.nlon - 1)
        
        # Interpolation weights
        dlat = ilat - i0
        dlon = ilon - j0
        
        # Interpolate
        v00 = self.model.data[i0, j0]
        v01 = self.model.data[i0, j1]
        v10 = self.model.data[i1, j0]
        v11 = self.model.data[i1, j1]
        
        v0 = v00 * (1 - dlon) + v01 * dlon
        v1 = v10 * (1 - dlon) + v11 * dlon
        
        geoid_height = v0 * (1 - dlat) + v1 * dlat
        
        return float(geoid_height)
    
    def ellipsoidal_to_orthometric(self, lat: float, lon: float, h_ellipsoid: float) -> Optional[float]:
        """
        Convert ellipsoidal height to orthometric height (MSL)
        
        Formula: H_ortho = h_ellipsoid - N_geoid
        
        Args:
            lat: Latitude in degrees
            lon: Longitude in degrees
            h_ellipsoid: Ellipsoidal height in meters (from GNSS)
            
        Returns:
            Orthometric height in meters (MSL), or None if no geoid model
        """
        geoid_height = self.get_geoid_height(lat, lon)
        
        if geoid_height is None:
            return None
        
        h_orthometric = h_ellipsoid - geoid_height
        
        logger.debug(f"Height conversion: {h_ellipsoid:.3f}m (ellipsoid) - {geoid_height:.3f}m (geoid) = {h_orthometric:.3f}m (MSL)")
        
        return h_orthometric
    
    def orthometric_to_ellipsoidal(self, lat: float, lon: float, h_orthometric: float) -> Optional[float]:
        """
        Convert orthometric height (MSL) to ellipsoidal height
        
        Formula: h_ellipsoid = H_ortho + N_geoid
        
        Args:
            lat: Latitude in degrees
            lon: Longitude in degrees
            h_orthometric: Orthometric height in meters (MSL)
            
        Returns:
            Ellipsoidal height in meters (WGS84), or None if no geoid model
        """
        geoid_height = self.get_geoid_height(lat, lon)
        
        if geoid_height is None:
            return None
        
        h_ellipsoid = h_orthometric + geoid_height
        
        return h_ellipsoid
    
    def estimate_geoid_height_approx(self, lat: float) -> float:
        """
        Rough geoid height estimate without model (fallback)
        
        Uses simplified spherical harmonic approximation.
        Accuracy: ~5-10 meters (for emergency use only).
        
        Args:
            lat: Latitude in degrees
            
        Returns:
            Approximate geoid height in meters
        """
        # Very rough approximation based on latitude
        # This is NOT accurate - only for fallback when no model available
        lat_rad = np.radians(lat)
        
        # Dominant spherical harmonic terms (C20, C22)
        N = -30.0 * (3 * np.sin(lat_rad)**2 - 1) / 2  # C20 term
        N += 10.0 * np.cos(lat_rad)**2 * np.cos(2 * 0)  # C22 term (simplified)
        
        logger.warning(f"Using approximate geoid height: {N:.1f}m (±10m accuracy)")
        return N
