import Foundation
import UIKit
import CryptoKit

/// Battery-only bridge for VoltScope. Never exports an Apple ID, tokens,
/// locations, device identifiers from iCloud's raw response, or cookies.
/// The URL handoff works even when the sideloader removes App Groups.
@MainActor
enum BatteryHandoff {
    struct Item: Codable {
        var id: String
        var name: String
        var percentage: Int?
        var connected: Bool
        var updated: Double
        var kind: String
    }

    struct Snapshot: Codable {
        var version = 1
        var updated: Double
        var items: [Item]
    }

    static let file = "voltscope-batteries.json"

    static func snapshot() -> Snapshot {
        let m = BLEMonitor.shared
        var items: [Item] = m.items.map { tracked in
            let state = m.state(tracked.id)
            let prior = m.lastBattery[tracked.id]
            let percentage = state.battery ?? prior?.level
            return Item(id: "findmyble:\(tracked.id.uuidString)",
                        name: String(tracked.title.prefix(80)),
                        percentage: percentage.flatMap { (0...100).contains($0) ? $0 : nil },
                        connected: state.isConnected,
                        updated: (state.battery == nil ? (prior?.at ?? .distantPast) : .now).timeIntervalSince1970,
                        kind: tracked.iconKind.rawValue)
        }

        // The Find My web feed already supplies batteryLevel for some Apple
        // devices (usually 0...1). Keep that reading, without its location.
        let findMy = FindMyStore.shared
        let lastRefresh = findMy.lastRefresh ?? .distantPast
        items += findMy.devices.map { device in
            let value = device.battery.flatMap { (0...1).contains($0) ? Int(($0 * 100).rounded()) : nil }
            let digest = SHA256.hash(data: Data(device.id.utf8))
            let stableID = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
            return Item(id: "findmy:\(stableID)",
                        name: String(device.name.prefix(80)),
                        percentage: value,
                        connected: device.online,
                        updated: lastRefresh.timeIntervalSince1970,
                        kind: device.symbol)
        }
        return Snapshot(updated: Date().timeIntervalSince1970,
                        items: Array(items.prefix(40)))
    }

    static func publishSnapshot() {
        AppGroup.write(snapshot(), file)
    }

    /// Invoked by a user tapping "Fetch from FindMyBLE" in VoltScope.
    /// A deep link returns cached readings across separate app sandboxes.
    static func openVoltScope() {
        let snap = snapshot()
        publishSnapshot()
        guard let data = try? JSONEncoder().encode(snap) else { return }
        let token = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var components = URLComponents()
        components.scheme = "voltscope"
        components.host = "import-batteries"
        components.queryItems = [URLQueryItem(name: "payload", value: token)]
        guard let url = components.url else { return }
        UIApplication.shared.open(url)
    }
}
