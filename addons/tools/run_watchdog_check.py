#!/usr/bin/env python3
"""
Watchdog Check Runner - Called by systemd timer
Runs all enabled monitoring checks
"""

import sys
import logging
from pathlib import Path

# Add GeoMaxima to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from features.watchdog.watchdog_controller import WatchdogController

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/var/log/rtkbase/watchdog.log'),
        logging.StreamHandler()
    ]
)

logger = logging.getLogger(__name__)


def main():
    """Run watchdog checks"""
    try:
        logger.info("Starting watchdog check...")
        
        controller = WatchdogController()
        results = controller.run_checks()
        
        if not results.get('enabled'):
            logger.info("Watchdog is disabled, skipping checks")
            return 0
        
        # Log results
        if results.get('incidents'):
            logger.warning(f"Found {len(results['incidents'])} incidents")
            for incident in results['incidents']:
                logger.warning(f"  - {incident['type']}: {incident['message']}")
        else:
            logger.info("All checks passed")
        
        logger.info("Watchdog check completed")
        return 0
        
    except Exception as e:
        logger.error(f"Watchdog check failed: {e}", exc_info=True)
        return 1


if __name__ == '__main__':
    sys.exit(main())
