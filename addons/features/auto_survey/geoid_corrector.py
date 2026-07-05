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
import os
import struct
from typing import Optional, Tuple
from dataclasses import dataclass
import numpy as np

logger = logging.getLogger(__name__)


TNL_GGF_MAGIC = b'TNL GRID FILE\x00'
TNL_GGF_HEADER_SIZE = 146


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

        Supports two formats:
        - Trimble TNL GGF binary format (146-byte header + grid data)
        - Legacy custom RTKLIB-style .ggf format:
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
                magic_probe = f.read(TNL_GGF_HEADER_SIZE)
                f.seek(0)
                if len(magic_probe) >= 30 and magic_probe[2:16] == TNL_GGF_MAGIC:
                    file_size = os.fstat(f.fileno()).st_size
                    data = f.read()
                    return self._load_tnl_ggf(data, ggf_path, file_size)

                return self._load_legacy_ggf(f, ggf_path)

        except Exception as e:
            msg = f"Failed to load geoid model from {ggf_path}: {e}"
            logger.error(msg)
            self.last_error = str(e)
            return False

    def _load_legacy_ggf(self, f, ggf_path: str) -> bool:
        """
        Load geoid model using the legacy custom text-header + float32 grid format.

        Args:
            f: Open binary file handle, positioned at the start of the file
            ggf_path: Path to .ggf file (used for model name / error messages)

        Returns:
            True if loaded successfully
        """
        try:
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
            expected_data_bytes = grid_size * 4
            header_bytes = f.tell()
            file_size = os.fstat(f.fileno()).st_size
            remaining_bytes = file_size - header_bytes
            if remaining_bytes <= 0 or expected_data_bytes > remaining_bytes * 2:
                msg = (
                    f"GGF header declares {nlat}x{nlon} grid "
                    f"({expected_data_bytes} bytes needed) but file only has "
                    f"{remaining_bytes} bytes remaining; refusing to allocate"
                )
                logger.error(msg)
                self.last_error = msg
                return False
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

    def _load_tnl_ggf(self, data: bytes, ggf_path: str, file_size: int) -> bool:
        """
        Parse the Trimble TNL GGF binary geoid grid format.

        Layout (146-byte header, little-endian):
        - [0:2]    version (uint16)
        - [2:16]   magic b'TNL GRID FILE\\x00'
        - [16:48]  Name (32-byte ASCII, null-padded)
        - [48:56]  LatMin (double)
        - [56:64]  LatMax (double)
        - [64:72]  LongMin (double)
        - [72:80]  LongMax (double)
        - [80:88]  LatInterval (double)
        - [88:96]  LongInterval (double)
        - [96:100] LatGridSize (uint32)
        - [100:104] LongGridSize (uint32)
        - [104:112] GridNPole (double)
        - [112:120] GridSPole (double)
        - [120:128] GridMissing (double) - sentinel value for missing cells
        - [128:136] GridScalar (double) - divisor when GIF_GRID_SCALED (flag_bytes[0] bit1) is set
        - [136:138] GridWindow (uint16)
        - [138:146] 8 flag bytes; flag_bytes[3] selects FLOAT (bit3) or LONG/int32 (bit2);
                    flag_bytes[0] bit1 (0x02) selects GIF_GRID_SCALED
        - [146:]    grid data, LatGridSize * LongGridSize values, row-major (rows of LongGridSize)

        Args:
            data: Full file contents
            ggf_path: Path to .ggf file (used for model name / error messages)
            file_size: Size of the file on disk, in bytes

        Returns:
            True if loaded successfully
        """
        GIF_GRID_LONG = 0x04   # bit2
        GIF_GRID_FLOAT = 0x08  # bit3

        if len(data) < TNL_GGF_HEADER_SIZE:
            msg = f"TNL GGF file too small for header: {len(data)} bytes"
            logger.error(msg)
            self.last_error = msg
            return False

        if data[2:16] != TNL_GGF_MAGIC:
            msg = "Invalid TNL GGF magic header"
            logger.error(msg)
            self.last_error = msg
            return False

        version, = struct.unpack('<H', data[0:2])
        if version > 1:
            msg = f"Unsupported TNL GGF version: {version}"
            logger.error(msg)
            self.last_error = msg
            return False

        name = data[16:48].replace(b'\x00', b'').decode('ascii', errors='ignore').strip()

        lat_min, = struct.unpack('<d', data[48:56])
        lat_max, = struct.unpack('<d', data[56:64])
        lon_min, = struct.unpack('<d', data[64:72])
        lon_max, = struct.unpack('<d', data[72:80])
        dlat, = struct.unpack('<d', data[80:88])
        dlon, = struct.unpack('<d', data[88:96])
        nlat, = struct.unpack('<I', data[96:100])
        nlon, = struct.unpack('<I', data[100:104])
        # GridNPole / GridSPole: stored but not critical for our use
        grid_npole, = struct.unpack('<d', data[104:112])
        grid_spole, = struct.unpack('<d', data[112:120])
        grid_missing, = struct.unpack('<d', data[120:128])
        grid_scalar, = struct.unpack('<d', data[128:136])
        # GridWindow: stored but not used
        grid_window, = struct.unpack('<H', data[136:138])
        flag_bytes = data[138:146]
        data_format_flag = flag_bytes[3]

        is_float = bool(data_format_flag & GIF_GRID_FLOAT)
        is_long = bool(data_format_flag & GIF_GRID_LONG)
        is_scaled = bool(flag_bytes[0] & 0x02)  # bit 1 of flag_bytes[0]

        if not is_float and not is_long:
            msg = f"Invalid TNL GGF data format flag byte: {data_format_flag:#x} (neither FLOAT nor LONG set)"
            logger.error(msg)
            self.last_error = msg
            return False

        if dlat <= 0 or dlon <= 0:
            msg = f"Invalid TNL GGF grid spacing: dlat={dlat}, dlon={dlon}"
            logger.error(msg)
            self.last_error = msg
            return False

        if nlat <= 0 or nlon <= 0:
            msg = f"Invalid TNL GGF grid dimensions: {nlat}x{nlon}"
            logger.error(msg)
            self.last_error = msg
            return False

        # Consistency checks between bounds, interval and grid size
        if abs((lat_min + (nlat - 1) * dlat) - lat_max) >= 0.0001:
            msg = (
                f"TNL GGF latitude bounds inconsistent: "
                f"lat_min={lat_min}, lat_max={lat_max}, dlat={dlat}, nlat={nlat}"
            )
            logger.error(msg)
            self.last_error = msg
            return False

        if abs((lon_min + (nlon - 1) * dlon) - lon_max) >= 0.0001:
            msg = (
                f"TNL GGF longitude bounds inconsistent: "
                f"lon_min={lon_min}, lon_max={lon_max}, dlon={dlon}, nlon={nlon}"
            )
            logger.error(msg)
            self.last_error = msg
            return False

        grid_size = nlat * nlon
        expected_data_bytes = grid_size * 4
        footer_bytes = 16 if version == 1 else 0
        expected_file_size = TNL_GGF_HEADER_SIZE + expected_data_bytes + footer_bytes

        if file_size != expected_file_size:
            msg = (
                f"TNL GGF file size mismatch: expected {expected_file_size} bytes "
                f"(header={TNL_GGF_HEADER_SIZE}, grid={expected_data_bytes}, footer={footer_bytes}), "
                f"got {file_size} bytes"
            )
            logger.error(msg)
            self.last_error = msg
            return False

        grid_bytes = data[TNL_GGF_HEADER_SIZE:TNL_GGF_HEADER_SIZE + expected_data_bytes]
        dtype = '<f4' if is_float else '<i4'
        grid_values = np.frombuffer(grid_bytes, dtype=dtype, count=grid_size).astype(np.float64)

        if is_scaled and grid_scalar not in (0, None):
            grid_values = grid_values / grid_scalar

        # Treat the "missing value" sentinel as NaN so callers/interpolation can detect gaps
        grid_values = np.where(np.isclose(grid_values, grid_missing), np.nan, grid_values)
        grid_values = grid_values.reshape(nlat, nlon)

        self.model = GeoidModel(
            name=name or ggf_path.split('/')[-1],
            lat_min=lat_min,
            lat_max=lat_max,
            lon_min=lon_min,
            lon_max=lon_max,
            dlat=dlat,
            dlon=dlon,
            nlat=nlat,
            nlon=nlon,
            data=grid_values
        )

        logger.info(f"Loaded TNL GGF geoid model: {self.model.name} (v{version})")
        logger.info(f"Geoid grid: {nlat}x{nlon}, spacing: {dlat}°x{dlon}°")
        logger.info(f"Height range: {np.nanmin(grid_values):.2f}m to {np.nanmax(grid_values):.2f}m")
        return True

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
