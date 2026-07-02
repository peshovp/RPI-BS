"""
Analytics Controller
Real-time GNSS data processing and analytics with advanced features
"""

import logging
import json
import csv
import io
from typing import Dict, List, Optional, Tuple
from datetime import datetime, timedelta
from collections import deque
import threading

logger = logging.getLogger(__name__)


class AnalyticsController:
    """
    Controller for processing GNSS analytics data
    Features:
    - Real-time satellite tracking with elevation/azimuth
    - Historical SNR data storage
    - Alert system for fix loss and low SNR
    - Data export (CSV/JSON)
    """
    
    def __init__(self, max_history_hours: int = 24):
        self.latest_satellite_data = []
        self.latest_status = {}
        self.sat_info_cache = {}  # Cache for elevation/azimuth
        
        # Historical data storage (24 hours by default)
        self.max_history_points = max_history_hours * 720  # 5sec intervals
        self.snr_history = {}  # {prn: deque([(timestamp, snr), ...])}
        self.fix_history = deque(maxlen=self.max_history_points)
        
        # Alert state
        self.alerts = []
        self.last_fix_type = None
        self.low_snr_threshold = 25  # dB
        
        # Thread lock for concurrent access
        self.lock = threading.Lock()
        
        logger.info(f"AnalyticsController initialized (history: {max_history_hours}h)")
    
    def get_satellite_info(self, rtkc) -> Dict[str, Tuple[float, float]]:
        """
        Get elevation and azimuth from RTKLIB satinfo command
        
        Args:
            rtkc: RTK controller instance
            
        Returns:
            Dict mapping PRN to (elevation, azimuth) tuple
        """
        try:
            # Check if RTKLIB is running
            if not hasattr(rtkc, 'child'):
                logger.warning("RTK controller has no child process (RTKLIB not initialized)")
                return {}
            
            if not hasattr(rtkc, 'launched') or not rtkc.launched:
                logger.warning("RTKLIB not launched - cannot get satellite info")
                return {}
            
            if not hasattr(rtkc, 'semaphore'):
                logger.error("RTK controller has no semaphore")
                return {}
            
            rtkc.semaphore.acquire()
            
            # Send satinfo command to RTKLIB
            try:
                rtkc.child.send("satinfo\r\n")
            except Exception as e:
                logger.error(f"Failed to send satinfo command: {e}")
                rtkc.semaphore.release()
                return {}
            
            if rtkc.expectAnswer("get satinfo", timeout=2) < 0:
                logger.warning("No response from RTKLIB satinfo command")
                rtkc.semaphore.release()
                return {}
            
            response = rtkc.child.before.decode().split("\r\n")
            response = [line for line in response if line.strip()]
            
            rtkc.semaphore.release()
            
            # Parse satinfo output
            # Format: SAT   Az(deg)  El(deg)  ...
            sat_info = {}
            
            for line in response:
                if "SAT" in line:
                    continue  # Skip header
                
                parts = line.split()
                if len(parts) >= 3:
                    try:
                        prn = parts[0]
                        azimuth = float(parts[1])
                        elevation = float(parts[2])
                        sat_info[prn] = (elevation, azimuth)
                    except (ValueError, IndexError):
                        continue
            
            # Cache the results
            if sat_info:
                self.sat_info_cache = sat_info
                logger.debug(f"Parsed {len(sat_info)} satellites from satinfo")
            else:
                logger.warning("No satellites in satinfo response")
            
            return sat_info
            
        except Exception as e:
            logger.error(f"Failed to get satellite info: {e}", exc_info=True)
            if hasattr(rtkc, 'semaphore'):
                try:
                    rtkc.semaphore.release()
                except:
                    pass
            return self.sat_info_cache  # Return cached data
    
    def process_satellite_data(self, obs_data: Dict, rtkc=None) -> List[Dict]:
        """
        Process satellite observation data from RTKBase
        
        Args:
            obs_data: Dictionary with satellite PRN as key and SNR as value
            rtkc: Optional RTK controller for elevation/azimuth
        
        Returns:
            List of satellite dictionaries with enhanced data
        """
        satellites = []
        timestamp = datetime.now()
        
        # Get elevation/azimuth if RTK controller available
        sat_info = {}
        if rtkc:
            sat_info = self.get_satellite_info(rtkc)
        
        with self.lock:
            for prn, snr_str in obs_data.items():
                if prn == "gps_time":
                    continue
                    
                try:
                    snr = float(snr_str)
                    
                    # Get elevation and azimuth
                    elevation, azimuth = sat_info.get(prn, (None, None))
                    
                    # Determine constellation from PRN prefix
                    constellation = self._get_constellation(prn)
                    
                    sat_data = {
                        'prn': prn,
                        'snr': snr,
                        'constellation': constellation,
                        'used': snr >= 20,
                        'elevation': elevation,
                        'azimuth': azimuth,
                        'timestamp': timestamp.isoformat()
                    }
                    
                    satellites.append(sat_data)
                    
                    # Store in history
                    if prn not in self.snr_history:
                        self.snr_history[prn] = deque(maxlen=self.max_history_points)
                    
                    self.snr_history[prn].append((timestamp, snr))
                    
                    # Check for low SNR alert
                    if snr < self.low_snr_threshold:
                        self._add_alert('warning', f'Low SNR on {prn}: {snr:.1f} dB')
                    
                except (ValueError, TypeError) as e:
                    logger.warning(f"Failed to parse satellite {prn}: {e}")
                    continue
            
            self.latest_satellite_data = satellites
            
        return satellites
    
    def process_rtk_status(self, status_data: Dict) -> Dict:
        """
        Process RTK status data for quality metrics
        
        Args:
            status_data: Dictionary with RTK status information
        
        Returns:
            Dictionary with processed quality metrics
        """
        timestamp = datetime.now()
        
        stats = {
            'satellite_count': status_data.get('satellite_count', 0),
            'solution_status': status_data.get('solution_status', 'Unknown'),
            'fix_type': status_data.get('rtk', 'N/A'),
            'std_horizontal': status_data.get('std_horizontal', 0),
            'std_vertical': status_data.get('std_vertical', 0),
            'age_of_differential': status_data.get('age_of_differential', 0),
            'timestamp': timestamp.isoformat()
        }
        
        with self.lock:
            self.latest_status = stats
            
            # Store fix history
            self.fix_history.append((
                timestamp,
                stats['fix_type'],
                stats['satellite_count']
            ))
            
            # Check for fix loss alert
            if self.last_fix_type == 'Fix' and stats['fix_type'] != 'Fix':
                self._add_alert('danger', f'RTK Fix lost! Now: {stats["fix_type"]}')
            elif self.last_fix_type and self.last_fix_type != 'Fix' and stats['fix_type'] == 'Fix':
                self._add_alert('success', 'RTK Fix acquired!')
            
            self.last_fix_type = stats['fix_type']
        
        return stats
    
    def get_historical_snr(self, prn: str = None, hours: int = 1) -> Dict:
        """
        Get historical SNR data for graphing
        
        Args:
            prn: Specific satellite PRN (None for all)
            hours: Hours of history to return
            
        Returns:
            Dictionary with historical data
        """
        cutoff_time = datetime.now() - timedelta(hours=hours)
        
        with self.lock:
            if prn:
                # Single satellite
                if prn not in self.snr_history:
                    return {'prn': prn, 'data': []}
                
                history = [
                    {'timestamp': ts.isoformat(), 'snr': snr}
                    for ts, snr in self.snr_history[prn]
                    if ts >= cutoff_time
                ]
                
                return {'prn': prn, 'data': history}
            else:
                # All satellites
                result = {}
                for sat_prn, history in self.snr_history.items():
                    filtered = [
                        {'timestamp': ts.isoformat(), 'snr': snr}
                        for ts, snr in history
                        if ts >= cutoff_time
                    ]
                    if filtered:
                        result[sat_prn] = filtered
                
                return result
    
    def get_fix_history(self, hours: int = 1) -> List[Dict]:
        """
        Get historical fix type data
        
        Args:
            hours: Hours of history to return
            
        Returns:
            List of fix history entries
        """
        cutoff_time = datetime.now() - timedelta(hours=hours)
        
        with self.lock:
            history = [
                {
                    'timestamp': ts.isoformat(),
                    'fix_type': fix_type,
                    'satellite_count': sat_count
                }
                for ts, fix_type, sat_count in self.fix_history
                if ts >= cutoff_time
            ]
        
        return history
    
    def export_data(self, format: str = 'csv', hours: int = 24) -> str:
        """
        Export analytics data to CSV or JSON
        
        Args:
            format: 'csv' or 'json'
            hours: Hours of data to export
            
        Returns:
            Exported data as string
        """
        cutoff_time = datetime.now() - timedelta(hours=hours)
        
        # Collect all data points
        data_points = []
        
        with self.lock:
            for prn, history in self.snr_history.items():
                for ts, snr in history:
                    if ts >= cutoff_time:
                        constellation = self._get_constellation(prn)
                        
                        # Get elevation/azimuth from cache if available
                        elevation, azimuth = self.sat_info_cache.get(prn, (None, None))
                        
                        data_points.append({
                            'timestamp': ts.isoformat(),
                            'prn': prn,
                            'constellation': constellation,
                            'snr': snr,
                            'elevation': elevation,
                            'azimuth': azimuth
                        })
        
        # Sort by timestamp
        data_points.sort(key=lambda x: x['timestamp'])
        
        if format == 'csv':
            output = io.StringIO()
            if data_points:
                fieldnames = ['timestamp', 'prn', 'constellation', 'snr', 'elevation', 'azimuth']
                writer = csv.DictWriter(output, fieldnames=fieldnames)
                writer.writeheader()
                writer.writerows(data_points)
            return output.getvalue()
        else:  # json
            return json.dumps({
                'export_time': datetime.now().isoformat(),
                'duration_hours': hours,
                'data_points': len(data_points),
                'data': data_points
            }, indent=2)
    
    def get_alerts(self, limit: int = 10) -> List[Dict]:
        """
        Get recent alerts
        
        Args:
            limit: Maximum number of alerts to return
            
        Returns:
            List of recent alerts
        """
        with self.lock:
            return self.alerts[-limit:]
    
    def clear_alerts(self):
        """Clear all alerts"""
        with self.lock:
            self.alerts.clear()
    
    def _add_alert(self, level: str, message: str):
        """
        Add an alert to the alert list
        
        Args:
            level: 'success', 'info', 'warning', or 'danger'
            message: Alert message
        """
        alert = {
            'timestamp': datetime.now().isoformat(),
            'level': level,
            'message': message
        }
        
        self.alerts.append(alert)
        
        # Keep only last 100 alerts
        if len(self.alerts) > 100:
            self.alerts = self.alerts[-100:]
        
        logger.info(f"Alert [{level}]: {message}")
    
    def _get_constellation(self, prn: str) -> str:
        """
        Determine constellation from PRN prefix
        
        Args:
            prn: Satellite PRN (e.g., "G01", "R12")
        
        Returns:
            Constellation name
        """
        if not prn:
            return 'Unknown'
            
        prefix = prn[0].upper()
        
        constellations = {
            'G': 'GPS',
            'R': 'GLONASS',
            'E': 'Galileo',
            'C': 'BeiDou',
            'J': 'QZSS',
            'I': 'IRNSS',
            'S': 'SBAS'
        }
        
        return constellations.get(prefix, 'Unknown')
    
    def get_latest_data(self) -> Dict:
        """
        Get the latest processed satellite and status data
        
        Returns:
            Dictionary with latest satellite data and status
        """
        with self.lock:
            return {
                'satellites': self.latest_satellite_data.copy(),
                'status': self.latest_status.copy()
            }
