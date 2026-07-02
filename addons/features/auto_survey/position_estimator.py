"""
Position Estimator
=================

Statistical position estimation with outlier rejection and weighted averaging.

Uses robust statistics to compute precise base station coordinates from 24 hours
of FIX solutions, handling atmospheric delays, multipath, and satellite geometry changes.
"""

import logging
from typing import List, Dict, Tuple, Optional
from dataclasses import dataclass
import numpy as np
from scipy import stats

from .gnss_parser import GNSSEpoch

logger = logging.getLogger(__name__)


@dataclass
class PositionEstimate:
    """Final position estimate with confidence metrics"""
    lat: float  # degrees
    lon: float  # degrees
    height: float  # ellipsoidal height, meters
    std_lat: float  # standard deviation, degrees
    std_lon: float  # standard deviation, degrees
    std_height: float  # standard deviation, meters
    num_epochs: int  # number of epochs used
    rejected_epochs: int  # number of outliers removed
    mean_ratio: float  # mean ambiguity ratio
    mean_sats: float  # mean satellite count
    
    @property
    def horizontal_std_meters(self) -> float:
        """Approximate horizontal std dev in meters"""
        # Rough conversion: 1 deg ≈ 111 km at equator
        std_lat_m = self.std_lat * 111000
        std_lon_m = self.std_lon * 111000 * np.cos(np.radians(self.lat))
        return np.sqrt(std_lat_m**2 + std_lon_m**2)


class PositionEstimator:
    """
    Robust position estimation with outlier rejection
    
    Uses Modified Z-Score (MAD-based) for outlier detection to handle
    non-Gaussian distributions common in GNSS data.
    """
    
    def __init__(self, 
                 outlier_threshold: float = 3.5,
                 min_epochs: int = 100):
        """
        Args:
            outlier_threshold: Modified Z-score threshold (default: 3.5)
            min_epochs: Minimum epochs required for valid estimate (default: 100)
        """
        self.outlier_threshold = outlier_threshold
        self.min_epochs = min_epochs
    
    def estimate_position(self, epochs: List[GNSSEpoch]) -> Optional[PositionEstimate]:
        """
        Compute robust position estimate from GNSS epochs
        
        Steps:
        1. Remove outliers using Modified Z-Score (MAD)
        2. Weight by inverse variance (from solution std devs)
        3. Compute weighted mean and standard deviation
        
        Args:
            epochs: List of quality FIX epochs
            
        Returns:
            PositionEstimate or None if insufficient data
        """
        if len(epochs) < self.min_epochs:
            logger.warning(f"Insufficient epochs: {len(epochs)} < {self.min_epochs}")
            return None
        
        # Extract arrays (epochs are dicts from parser)
        lats = np.array([e['lat'] for e in epochs])
        lons = np.array([e['lon'] for e in epochs])
        heights = np.array([e['height'] for e in epochs])
        
        # Weights from solution quality (inverse variance)
        # Use sde (East std) and sdn (North std) for horizontal, sdu for vertical
        sde = np.array([e.get('sde', 1.0) for e in epochs])
        sdn = np.array([e.get('sdn', 1.0) for e in epochs])
        sdu = np.array([e.get('sdu', 1.0) for e in epochs])
        
        # Horizontal std is the larger of East/North uncertainties
        horizontal_std = np.maximum(sde, sdn)
        horizontal_std[horizontal_std == 0] = 1.0  # Avoid division by zero
        sdu[sdu == 0] = 1.0
        
        weights_h = 1.0 / (horizontal_std**2)
        weights_v = 1.0 / (sdu**2)
        
        # Normalize weights
        weights_h /= np.sum(weights_h)
        weights_v /= np.sum(weights_v)
        
        # Outlier removal
        logger.info("Detecting outliers using Modified Z-Score...")
        lat_mask = self._detect_outliers(lats)
        lon_mask = self._detect_outliers(lons)
        height_mask = self._detect_outliers(heights)
        
        # Combined mask: keep only inliers in all dimensions
        inlier_mask = lat_mask & lon_mask & height_mask
        num_rejected = len(epochs) - np.sum(inlier_mask)
        
        logger.info(f"Rejected {num_rejected} outliers ({num_rejected/len(epochs)*100:.1f}%)")
        
        if np.sum(inlier_mask) < self.min_epochs:
            logger.error("Too many outliers removed, insufficient data remains")
            return None
        
        # Filter to inliers
        lats = lats[inlier_mask]
        lons = lons[inlier_mask]
        heights = heights[inlier_mask]
        weights_h = weights_h[inlier_mask]
        weights_v = weights_v[inlier_mask]
        inlier_epochs = [e for i, e in enumerate(epochs) if inlier_mask[i]]
        
        # Re-normalize weights after filtering
        weights_h /= np.sum(weights_h)
        weights_v /= np.sum(weights_v)
        
        # Weighted mean
        mean_lat = np.sum(lats * weights_h)
        mean_lon = np.sum(lons * weights_h)
        mean_height = np.sum(heights * weights_v)
        
        # Weighted standard deviation
        std_lat = np.sqrt(np.sum(weights_h * (lats - mean_lat)**2))
        std_lon = np.sqrt(np.sum(weights_h * (lons - mean_lon)**2))
        std_height = np.sqrt(np.sum(weights_v * (heights - mean_height)**2))
        
        # Quality metrics (from dict fields)
        # ratio may not be present in SPP solutions, default to 0
        mean_ratio = np.mean([e.get('ratio', 0.0) for e in inlier_epochs])
        # ns is number of satellites in .pos file
        mean_sats = np.mean([e.get('ns', 0) for e in inlier_epochs])
        
        estimate = PositionEstimate(
            lat=mean_lat,
            lon=mean_lon,
            height=mean_height,
            std_lat=std_lat,
            std_lon=std_lon,
            std_height=std_height,
            num_epochs=len(inlier_epochs),
            rejected_epochs=num_rejected,
            mean_ratio=mean_ratio,
            mean_sats=mean_sats
        )
        
        logger.info(f"Position estimate: {mean_lat:.8f}°, {mean_lon:.8f}°, {mean_height:.3f}m")
        logger.info(f"Horizontal std: {estimate.horizontal_std_meters*1000:.1f}mm")
        logger.info(f"Vertical std: {std_height*1000:.1f}mm")
        
        return estimate
    
    def _detect_outliers(self, data: np.ndarray) -> np.ndarray:
        """
        Detect outliers using Modified Z-Score (MAD-based)
        
        More robust than standard Z-score for non-Gaussian distributions.
        
        Args:
            data: 1D array of values
            
        Returns:
            Boolean mask (True = inlier, False = outlier)
        """
        median = np.median(data)
        mad = np.median(np.abs(data - median))
        
        if mad == 0:
            # All values identical or near-identical
            return np.ones(len(data), dtype=bool)
        
        # Modified Z-score
        modified_z_scores = 0.6745 * (data - median) / mad
        
        # Inliers have |modified_z| < threshold
        return np.abs(modified_z_scores) < self.outlier_threshold
    
    def compute_convergence(self, epochs: List[GNSSEpoch], 
                           window_hours: int = 1) -> List[Dict]:
        """
        Compute position estimates over sliding time windows
        
        Useful for monitoring survey convergence and stability.
        
        Args:
            epochs: Sorted list of epochs (oldest to newest)
            window_hours: Window size in hours
            
        Returns:
            List of dicts with timestamp, position, std devs
        """
        if not epochs:
            return []
        
        # Sort by timestamp
        epochs_sorted = sorted(epochs, key=lambda e: e.timestamp)
        
        # Compute window in epochs (assume 1Hz data)
        window_size = window_hours * 3600
        
        convergence = []
        for i in range(len(epochs_sorted)):
            if i < window_size:
                continue
            
            window_epochs = epochs_sorted[i-window_size:i]
            estimate = self.estimate_position(window_epochs)
            
            if estimate:
                convergence.append({
                    'timestamp': epochs_sorted[i].timestamp,
                    'lat': estimate.lat,
                    'lon': estimate.lon,
                    'height': estimate.height,
                    'std_h': estimate.horizontal_std_meters,
                    'std_v': estimate.std_height,
                    'num_epochs': estimate.num_epochs
                })
        
        return convergence
