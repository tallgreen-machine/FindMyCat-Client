//
//  FindMyCatClient_SingleFile.swift
//  For review: All logic in one file
//
//  To use: Paste into a new SwiftUI macOS app's ContentView.swift and set as main entry point.
//

import SwiftUI

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

class MainViewModel: ObservableObject {
    private let dbPath = (NSHomeDirectory() + "/Library/Caches/com.apple.findmy.fmipcore/Items.data")
    private let serverURL = URL(string: "https://findmycat.goldmansoap.com")!
    private let pollInterval: TimeInterval = 10
    private let batchSize = 10
    private let authToken: String? = nil // Set token if needed
    
    @Published var connectionStatus: ConnectionStatus = .unknown
    @Published var lastUpdate: Date? = nil
    @Published var lastError: String? = nil
    @Published var devices: [DeviceLocation] = []
    @Published var log: String = ""
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
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }
    
    func poll() {
        testConnection()
        fetchLocationsAndSend()
    }
    
    func testConnection() {
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
                } else if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    self.connectionStatus = .connected
                    self.appendLog("✅ Connected to server")
                } else {
                    self.connectionStatus = .error
                    self.lastError = "Server error"
                    self.appendLog("❌ Server error")
                }
            }
        }
        task.resume()
    }
    
    func fetchLocationsAndSend() {
        let locations = fetchLocations()
        DispatchQueue.main.async {
            self.devices = locations
        }
        sendLocations(locations)
    }
    
    func fetchLocations() -> [DeviceLocation] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dbPath)) else {
            appendLog("Error reading Find My cache. Grant Full Disk Access to this app in System Settings > Privacy & Security.")
            return []
        }
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
        var request = URLRequest(url: serverURL.appendingPathComponent("api/location"))
        request.httpMethod = "POST"
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let payload: [String: Any] = [
            "deviceId": device.id,
            "latitude": device.latitude,
            "longitude": device.longitude,
            "timestamp": device.isoTime
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.appendLog("❌ Send error: \(error.localizedDescription)")
                } else if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    self.appendLog("✅ Location sent for \(device.id)")
                } else {
                    self.appendLog("❌ Server rejected location for \(device.id)")
                }
            }
        }
        task.resume()
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

struct ContentView: View {
    @StateObject private var viewModel = MainViewModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Circle()
                    .fill(viewModel.connectionStatus.color)
                    .frame(width: 16, height: 16)
                Text(viewModel.connectionStatus.description)
                    .font(.headline)
                Spacer()
                Button("Test Connection") {
                    viewModel.testConnection()
                }
                Button("Send Now") {
                    viewModel.sendNow()
                }
            }
            Divider()
            Text("Last Update: \(viewModel.lastUpdateString)")
            Text("Last Error: \(viewModel.lastError ?? "None")")
                .foregroundColor(.red)
            Divider()
            Text("Devices:")
                .font(.title2)
            List(viewModel.devices, id: \. id) { device in
                VStack(alignment: .leading) {
                    Text(device.displayName)
                        .font(.headline)
                    Text("Lat: \(device.latitude), Lon: \(device.longitude)")
                        .font(.subheadline)
                    Text("Updated: \(device.isoTime)")
                        .font(.caption)
                }
            }
            Divider()
            Text("Log:")
                .font(.title2)
            ScrollView {
                Text(viewModel.log)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
        }
        .padding()
        .frame(minWidth: 500, minHeight: 600)
        .onAppear {
            viewModel.start()
        }
    }
}

@main
struct FindMyCatClientApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
