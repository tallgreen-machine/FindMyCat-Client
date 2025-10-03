# FindMyCatClient (macOS)

A native SwiftUI macOS app that monitors Apple's Find My cache and sends updates to the FindMyCat web server.

## Features
- Periodically checks server health and shows connection status
- Reads and parses Find My cache file at `~/Library/Caches/com.apple.findmy.fmipcore/Items.data`
- Displays device locations and status
- Sends location updates to server, batching as needed
- Logs status and errors, with a viewable log in the app
- UI includes connection status, last update time, last error, manual 'Send Now' and 'Test Connection' buttons, and log viewer
- No user input for server URL or token (hardcoded in code)

## Usage
1. Open the `FindMyCatClient` folder in Xcode
2. Build and run the app
3. Grant Full Disk Access to the app in System Settings > Privacy & Security so it can read the Find My cache

## Customization
- To set a different server URL or auth token, edit `MainViewModel.swift`

---

This project was generated from a Python script and is designed for native macOS use.
