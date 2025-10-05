#!/usr/bin/env python3
"""
FindMyCat Web Client - Mac Edition
Monitors Apple's Find My cache and sends updates to the web server
"""

import os
import json
import time
import requests
from datetime import datetime
from typing import List, Dict, Optional, Tuple
import argparse
import logging

# --- Config ---
DB_PATH = os.path.expanduser(
    "~/Library/Caches/com.apple.findmy.fmipcore/Items.data"
)
LOG_FILE = "findmycat_client.log"
DEFAULT_SERVER_URL = "https://findmycat.goldmansoap.com"  # Production server
POLL_INTERVAL = 10  # seconds
BATCH_SIZE = 10  # maximum locations to send in one request

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

class FindMyCatClient:
    def __init__(self, server_url: str = DEFAULT_SERVER_URL, token: Optional[str] = None):
        self.server_url = server_url.rstrip('/')
        self.last_mtime: Optional[float] = None
        self.last_seen: Dict[str, int] = {}
        self.session = requests.Session()
        self.session.timeout = 30
        self.token = token
        if self.token:
            self.session.headers.update({"Authorization": f"Bearer {self.token}"})
            logger.info("🔐 Auth token loaded; client will send authenticated updates")
        
    def test_connection(self) -> bool:
        """Test connection to the web server"""
        try:
            response = self.session.get(f"{self.server_url}/health")
            if response.status_code == 200:
                health_data = response.json()
                logger.info(f"✅ Connected to server: {health_data}")
                return True
            else:
                logger.error(f"❌ Server health check failed: {response.status_code}")
                return False
        except requests.RequestException as e:
            logger.error(f"❌ Cannot connect to server: {e}")
            return False

    def fetch_locations(self) -> List[Tuple[str, float, float, int, str]]:
        """Read JSON cache and return list of (device_id, lat, lon, ts, iso_time)."""
        try:
            with open(DB_PATH, "r") as f:
                data = json.load(f)
        except FileNotFoundError as e:
            logger.error(f"Error reading Find My cache: {e}")
            return []
        except PermissionError as e:
            logger.error(f"Permission error reading Find My cache: {e}")
            logger.error("This is likely macOS privacy (TCC). Grant Full Disk Access to your terminal (Terminal.app/iTerm/VS Code) in System Settings -> Privacy & Security so the client can read the cache file.")
            return []
        except json.JSONDecodeError as e:
            logger.error(f"Error parsing Find My cache JSON: {e}")
            logger.debug("Cache file may be binary or unexpectedly formatted; consider exporting a copy and inspecting it.")
            return []
        except Exception as e:
            logger.error(f"Error reading Find My cache: {e}")
            return []

        items = data if isinstance(data, list) else data.get("items", [])
        rows = []

        for item in items:
            device_id = item.get("id") or item.get("identifier") or "unknown"
            location = item.get("location") or {}

            # Skip safeLocations & stale pings
            if location.get("positionType") == "safeLocation":
                continue
            if location.get("isOld", False):
                continue

            timestamp = location.get("timeStamp")
            latitude = location.get("latitude")
            longitude = location.get("longitude")
            
            if timestamp is None or latitude is None or longitude is None:
                continue

            # Convert timestamp to ISO format
            iso_time = datetime.fromtimestamp(timestamp/1000).isoformat()
            rows.append((device_id, latitude, longitude, timestamp, iso_time))

        return rows

    def send_location_update(self, device_id: str, latitude: float, longitude: float, timestamp: str) -> Optional[bool]:
        """Send a single location update to the server
        Returns:
          - True:  server accepted and stored a NEW location
          - False: server says this location is already known (duplicate/old)
          - None:  a network/server error occurred
        """
        payload = {
            "deviceId": device_id,
            "latitude": latitude,
            "longitude": longitude,
            "timestamp": timestamp
        }

        try:
            response = self.session.post(
                f"{self.server_url}/api/locations/update",
                json=payload,
                headers={"Content-Type": "application/json"}
            )

            if response.status_code == 200:
                result = response.json()
                if result.get("success"):
                    # True if new point stored, False if duplicate/old
                    return True if result.get("isNew", False) else False
                else:
                    logger.error(f"Server rejected update: {result}")
                    return None
            else:
                logger.error(f"Server error {response.status_code}: {response.text}")
                return None

        except requests.RequestException as e:
            logger.error(f"Failed to send location update: {e}")
            return None

    def send_batch_update(self, updates: List[Dict]) -> Optional[Dict]:
        """Send multiple location updates in a single request"""
        try:
            response = self.session.post(
                f"{self.server_url}/api/locations/batch-update",
                json=updates,
                headers={"Content-Type": "application/json"}
            )
            
            if response.status_code == 200:
                return response.json()
            else:
                logger.error(f"Batch update failed {response.status_code}: {response.text}")
                return None
                
        except requests.RequestException as e:
            logger.error(f"Failed to send batch update: {e}")
            return None

    def process_locations(self, locations: List[Tuple[str, float, float, int, str]]) -> None:
        """Process locations and send new ones to server"""
        if not locations:
            logger.info("📍 No locations found in Find My cache")
            return

        new_updates = []
        
        for device_id, latitude, longitude, timestamp, iso_time in locations:
            previous_timestamp = self.last_seen.get(device_id, 0)
            
            if timestamp > previous_timestamp:
                # New location
                new_updates.append({
                    "deviceId": device_id,
                    "latitude": latitude,
                    "longitude": longitude,
                    "timestamp": iso_time
                })
                self.last_seen[device_id] = timestamp
                logger.info(f"📍 [NEW] {device_id} @ {latitude:.6f},{longitude:.6f} {iso_time}")
            else:
                # Not new
                logger.debug(f"📍 [OLD] {device_id} still at {latitude:.6f},{longitude:.6f} {iso_time}")

        if new_updates:
            if len(new_updates) == 1:
                # Single update
                update = new_updates[0]
                success = self.send_location_update(
                    update["deviceId"],
                    update["latitude"], 
                    update["longitude"],
                    update["timestamp"]
                )
                if success is True:
                    logger.info(f"✅ New location stored for {update['deviceId']}")
                elif success is False:
                    logger.info(f"➖ No change for {update['deviceId']} (already up to date)")
                else:
                    logger.error(f"❌ Failed to send update for {update['deviceId']}")
            else:
                # Batch update
                result = self.send_batch_update(new_updates)
                if result and result.get("success"):
                    logger.info(f"✅ Sent batch update: {result['processed']} processed, {result['newLocations']} new")
                else:
                    logger.error(f"❌ Batch update failed")
        else:
            logger.info("📍 No new locations to send")

    def run_once(self) -> bool:
        """Run one cycle of location checking and updating"""
        try:
            # Check if cache file has been modified
            current_mtime = os.path.getmtime(DB_PATH)
            
            if self.last_mtime is None or current_mtime > self.last_mtime:
                logger.info(f"🔄 Find My cache updated (mtime: {current_mtime})")
                self.last_mtime = current_mtime
                
                # Fetch and process locations
                locations = self.fetch_locations()
                self.process_locations(locations)
                return True
            else:
                logger.debug("⏸️  No cache update detected")
                return False
                
        except FileNotFoundError:
            logger.error(f"❌ Find My cache file not found: {DB_PATH}")
            logger.error("   Make sure Find My is enabled and you're logged into iCloud")
            return False
        except Exception as e:
            logger.error(f"❌ Unexpected error in run_once: {e}")
            return False

    def run_continuous(self, poll_interval: int = POLL_INTERVAL) -> None:
        """Run continuous monitoring loop"""
        logger.info(f"🐱 FindMyCat client starting...")
        logger.info(f"📡 Server: {self.server_url}")
        logger.info(f"📁 Cache: {DB_PATH}")
        logger.info(f"⏰ Poll interval: {poll_interval}s")
        
        # Test initial connection
        if not self.test_connection():
            logger.error("❌ Cannot connect to server. Please check server is running.")
            return

        consecutive_errors = 0
        max_consecutive_errors = 5
        
        try:
            while True:
                try:
                    success = self.run_once()
                    if success:
                        consecutive_errors = 0
                    
                    time.sleep(poll_interval)
                    
                except Exception as e:
                    consecutive_errors += 1
                    logger.error(f"❌ Error in monitoring loop: {e}")
                    
                    if consecutive_errors >= max_consecutive_errors:
                        logger.error(f"❌ Too many consecutive errors ({consecutive_errors}). Stopping.")
                        break
                    
                    logger.info(f"⏳ Waiting {poll_interval}s before retry...")
                    time.sleep(poll_interval)
                    
        except KeyboardInterrupt:
            logger.info("🛑 Stopped by user")
        except Exception as e:
            logger.error(f"❌ Fatal error: {e}")
        finally:
            logger.info("👋 FindMyCat client stopped")

def main():
    global DB_PATH
    parser = argparse.ArgumentParser(description="FindMyCat Mac Client - Send AirTag locations to web server")
    parser.add_argument(
        "--server", 
        default=DEFAULT_SERVER_URL,
        help=f"Web server URL (default: {DEFAULT_SERVER_URL})"
    )
    parser.add_argument(
        "--db-path",
        help=f"Path to Find My cache (default: {DB_PATH})",
    )
    parser.add_argument(
        "--pair-code",
        help="Pair this Mac to your account using a pairing code generated from the web UI"
    )
    parser.add_argument(
        "--test", 
        action="store_true",
        help="Test connection and run once, then exit"
    )
    parser.add_argument(
        "--interval",
        type=int,
        default=POLL_INTERVAL,
        help=f"Polling interval in seconds (default: {POLL_INTERVAL})"
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Enable verbose logging"
    )
    
    args = parser.parse_args()
    
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    
    # Config persistence for token
    config_dir = os.path.expanduser("~/.findmycat")
    config_path = os.path.join(config_dir, "config.json")
    os.makedirs(config_dir, exist_ok=True)

    saved_token: Optional[str] = None
    if os.path.exists(config_path):
        try:
            with open(config_path, "r") as f:
                saved = json.load(f)
                if isinstance(saved, dict):
                    saved_token = saved.get("token")
                    saved_server = saved.get("server")
                    # Respect previously saved server URL unless --server was provided explicitly
                    if saved_server and not (args.server and args.server != DEFAULT_SERVER_URL):
                        args.server = saved_server
        except Exception as e:
            logger.warning(f"Could not read config file: {e}")

    # Allow overriding the Find My cache path for testing (--db-path)
    if args.db_path:
        DB_PATH = os.path.expanduser(args.db_path)

    client = FindMyCatClient(args.server, token=saved_token)

    # Pairing flow
    if args.pair_code:
        try:
            logger.info("🔗 Pairing with server using code...")
            # Server pairing endpoint is /api/pairing/claim (not /api/devices/pair)
            resp = client.session.post(
                f"{client.server_url}/api/pairing/claim",
                json={"code": args.pair_code},
                headers={"Content-Type": "application/json"},
                timeout=30,
            )
            if resp.status_code != 200:
                logger.error(f"❌ Pairing failed: {resp.status_code} {resp.text}")
                return
            # Parse JSON safely and include raw response text on failure for easier debugging
            try:
                data = resp.json()
            except Exception as e:
                logger.error(f"❌ Failed to parse pairing response as JSON: {e}")
                logger.debug(f"Pairing response text: {resp.text}")
                return
            token = data.get("token")
            if not token:
                logger.error("❌ Pairing response did not include a token")
                return
            # Save token & server to config
            to_save = {"token": token, "server": client.server_url}
            with open(config_path, "w") as f:
                json.dump(to_save, f, indent=2)
            logger.info("✅ Paired successfully. Token saved to ~/.findmycat/config.json")
            # Update session headers immediately
            client.token = token
            client.session.headers.update({"Authorization": f"Bearer {token}"})
        except Exception as e:
            logger.error(f"❌ Pairing error: {e}")
            return
    
    if args.test:
        logger.info("🧪 Running in test mode...")
        if client.test_connection():
            client.run_once()
            logger.info("✅ Test completed successfully")
        else:
            logger.error("❌ Test failed")
            exit(1)
    else:
        client.run_continuous(args.interval)

if __name__ == "__main__":
    main()