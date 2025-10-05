//
//  MainViewModel.swift
//  FindMyCatClient
//
//  Handles logic for FindMyCat macOS client
//

import Foundation
import SwiftUI

class MainViewModel: ObservableObject {
    // --- Config ---
    private let dbPath = (NSHomeDirectory() + "/Library/Caches/com.apple.findmy.fmipcore/Items.data")
    private var serverURL = URL(string: "https://findmycat.goldmansoap.com")!
    private let pollInterval: TimeInterval = 10
    private let batchSize = 10
    private var authToken: String? = nil // Loaded from config if available
    
    @Published var connectionStatus: ConnectionStatus = .unknown
    @Published var lastUpdate: Date? = nil
    @Published var lastError: String? = nil
    @Published var devices: [DeviceLocation] = []
    @Published var log: String = ""
    @Published var isPaired: Bool = false
    @Published var pairedCode: String? = nil
    private var timer: Timer?
    
    var lastUpdateString: String {
        if let date = lastUpdate {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .medium
            return formatter.string(from: date)
        }
        return "Never"
    }
    
    func start() {
        // Load saved config (token/server) if present
        loadConfigFromDisk()
        // Determine paired state from token
        self.isPaired = (authToken?.isEmpty == false)
        if !isPaired {
            appendLog("ℹ️ Not paired. Enter your pairing code above to pair with the server.")
        }
        // Debug: surface whether the Find My cache path exists when starting
        let exists = FileManager.default.fileExists(atPath: dbPath)
        print("FindMyCatClient: start() - dbPath: \(dbPath) exists: \(exists)")
        appendLog("DEBUG: start() - dbPath: \(dbPath) exists: \(exists)")

        if isPaired {
            startPolling()
        }
    }
    
    func poll() {
        guard isPaired else {
            appendLog("ℹ️ Not paired yet. Skipping network calls.")
            return
        }
        testConnection()
        fetchLocationsAndSend()
    }

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    func pair(with code: String) {
        appendLog("🔗 Pairing with server using code…")
        var request = URLRequest(url: serverURL.appendingPathComponent("api/pairing/claim"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = ["code": code]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.appendLog("❌ Pairing error: \(error.localizedDescription)")
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    self.appendLog("❌ Pairing failed: no HTTP response")
                    return
                }
                let status = http.statusCode
                let bodyStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if status != 200 {
                    self.appendLog("❌ Pairing failed (HTTP \(status)) \(bodyStr)")
                    return
                }
                // Parse JSON and extract token
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let token = json["token"] as? String,
                      !token.isEmpty else {
                    self.appendLog("❌ Pairing response missing token: \(bodyStr)")
                    return
                }
                self.authToken = token
                self.isPaired = true
                self.pairedCode = code
                self.saveConfigToDisk(token: token, server: self.serverURL.absoluteString, pairCode: code)
                self.appendLog("✅ Paired successfully. Token saved to ~/.findmycat/config.json")
                self.startPolling()
            }
        }
        task.resume()
    }
    
    func testConnection() {
        guard isPaired else {
            appendLog("ℹ️ Not paired yet. Skipping health check.")
            return
        }
        var request = URLRequest(url: serverURL.appendingPathComponent("health"))
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.connectionStatus = .error
                    self.lastError = error.localizedDescription
                    self.appendLog("❌ Cannot connect: \(error.localizedDescription)")
                } else if let http = response as? HTTPURLResponse {
                    let status = http.statusCode
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    if (200...299).contains(status) {
                        self.connectionStatus = .connected
                        self.appendLog("✅ Health OK (HTTP \(status)) \(body.isEmpty ? "" : "- \(body.prefix(200))")")
                    } else {
                        self.connectionStatus = .error
                        self.lastError = "Server error (HTTP \(status))"
                        self.appendLog("❌ Health failed (HTTP \(status)) \(body.isEmpty ? "" : "- \(body.prefix(300))")")
                    }
                }
            }
        }
        task.resume()
    }
    
    func fetchLocationsAndSend() {
        guard isPaired else { return }
        let locations = fetchLocations()
        DispatchQueue.main.async {
            self.devices = locations
        }
        sendLocations(locations)
    }
    
    func fetchLocations() -> [DeviceLocation] {
        // Debug: check if file exists and log size when reading
        let exists = FileManager.default.fileExists(atPath: dbPath)
        print("FindMyCatClient: fetchLocations() - dbPath: \(dbPath) exists: \(exists)")
        appendLog("DEBUG: fetchLocations() - dbPath: \(dbPath) exists: \(exists)")

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dbPath)) else {
            appendLog("Error reading Find My cache. Grant Full Disk Access to this app in System Settings > Privacy & Security.")
            return []
        }
        print("FindMyCatClient: fetchLocations() - read data length: \(data.count)")
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            appendLog("Error parsing Find My cache JSON.")
            return []
        }
        let items: [[String: Any]]
        if let arr = json as? [[String: Any]] {
            items = arr
        } else if let dict = json as? [String: Any], let arr = dict["items"] as? [[String: Any]] {
            items = arr
        } else {
            appendLog("Cache format not recognized.")
            return []
        }
        var rows: [DeviceLocation] = []
        for item in items {
            let deviceId = (item["id"] as? String) ?? (item["identifier"] as? String) ?? "unknown"
            guard let location = item["location"] as? [String: Any] else { continue }
            if location["positionType"] as? String == "safeLocation" { continue }
            if location["isOld"] as? Bool == true { continue }
            guard let timestamp = location["timeStamp"] as? Double,
                  let latitude = location["latitude"] as? Double,
                  let longitude = location["longitude"] as? Double else { continue }
            let isoTime = Date(timeIntervalSince1970: timestamp/1000).iso8601String
            rows.append(DeviceLocation(id: deviceId, latitude: latitude, longitude: longitude, timestamp: timestamp, isoTime: isoTime))
        }
        return rows
    }
    
    func sendLocations(_ locations: [DeviceLocation]) {
        guard isPaired else { return }
        let batches = locations.chunked(into: batchSize)
        for batch in batches {
            for device in batch {
                sendLocationUpdate(device)
            }
        }
        DispatchQueue.main.async {
            self.lastUpdate = Date()
        }
    }
    
    func sendLocationUpdate(_ device: DeviceLocation) {
        guard isPaired else { return }
        let payload: [String: Any] = [
            "deviceId": device.id,
            "latitude": device.latitude,
            "longitude": device.longitude,
            "timestamp": device.isoTime
        ]
        if let dbg = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
           let dbgStr = String(data: dbg, encoding: .utf8) {
            appendLog("DEBUG: POST /api/locations/update payload for \(device.id):\n\(dbgStr.prefix(500))")
        }
        // Build request for single-update endpoint
        var request = URLRequest(url: serverURL.appendingPathComponent("api/locations/update"))
        request.httpMethod = "POST"
        if let token = authToken { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.appendLog("❌ Send error: \(error.localizedDescription)")
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    self.appendLog("❌ No HTTP response for \(device.id) at /api/locations/update")
                    return
                }
                let status = http.statusCode
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if (200...299).contains(status) {
                    self.appendLog("✅ Location sent for \(device.id) (HTTP \(status)) \(body.isEmpty ? "" : "- \(body.prefix(200))")")
                } else {
                    self.appendLog("❌ Server rejected location for \(device.id) (HTTP \(status)) \(body.isEmpty ? "" : "- \(body.prefix(500))")")
                }
            }
        }
        task.resume()
    }

    // Load saved token/server to mimic Python client behavior
    private func loadConfigFromDisk() {
        let configPath = (NSHomeDirectory() as NSString).appendingPathComponent(".findmycat/config.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let token = json["token"] as? String, !token.isEmpty {
            self.authToken = token
            self.isPaired = true
            appendLog("🔐 Loaded auth token from ~/.findmycat/config.json")
        }
        if let code = json["pairCode"] as? String, !code.isEmpty {
            self.pairedCode = code
            appendLog("🔗 Loaded paired code from config: \(code)")
        }
        if let server = json["server"] as? String, let url = URL(string: server), server.isEmpty == false {
            self.serverURL = url
            appendLog("🌐 Server overridden from config: \(server)")
        }
    }

    private func saveConfigToDisk(token: String, server: String, pairCode: String?) {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".findmycat")
        let path = (dir as NSString).appendingPathComponent("config.json")
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            var obj: [String: Any] = ["token": token, "server": server]
            if let code = pairCode, !code.isEmpty { obj["pairCode"] = code }
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
            try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
        } catch {
            appendLog("⚠️ Failed to save config: \(error.localizedDescription)")
        }
    }
    
    func sendNow() {
        poll()
    }
    
    private func appendLog(_ message: String) {
        let timestamp = Date().iso8601String
        log += "[\(timestamp)] \(message)\n"
        if log.count > 8000 {
            log = String(log.suffix(8000))
        }
    }
}

extension Date {
    var iso8601String: String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: self)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

struct DeviceLocation: Identifiable {
    let id: String
    let latitude: Double
    let longitude: Double
    let timestamp: Double
    let isoTime: String
    var displayName: String { id }
}

enum ConnectionStatus {
    case unknown, connected, error
    var description: String {
        switch self {
        case .unknown: return "Unknown"
        case .connected: return "Connected"
        case .error: return "Error"
        }
    }
    var color: Color {
        switch self {
        case .unknown: return .gray
        case .connected: return .green
        case .error: return .red
        }
    }
}
