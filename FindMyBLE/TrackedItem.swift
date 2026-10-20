import Foundation
import CoreBluetooth
import SwiftUI

/// One thing you don't want to leave behind. Everything here is per item and persisted.
struct TrackedItem: Codable, Identifiable, Equatable {
    var id = UUID()
    /// The advertised name when the item was added. Reference only, never shown as the title.
    var bluetoothName: String
    /// Cosmetic name shown in the app and in alerts. Not a Bluetooth rename.
    var displayName: String = ""
    /// Any advertised name starting with this counts as the item. Devices like the LARQ cap
    /// rotate the random part of their name ("LARQ_xxxx"), so exact matching would lose it.
    var matchPrefix: String
    /// Advertised service UUIDs. iOS only lets apps scan in the background for these.
    var services: [String] = []

    var alertsEnabled = true
    /// Only alert once the phone physically leaves the area where the item was last heard.
    var alertOnLeaveArea = true
    var notifyReturns = false
    /// Seconds without a sighting before it counts as left behind (timer mode only).
    var graceSeconds: Double = 180
    /// Radius of the item's geofence, metres.
    var areaRadius: Double = 150
    var holdConnection = false
    var disablePowerSaving = false
    var colorIndex = 0

    static let radiusRange: ClosedRange<Double> = 50...1500

    init(bluetoothName: String, matchPrefix: String, services: [String], colorIndex: Int) {
        self.bluetoothName = bluetoothName
        self.matchPrefix = matchPrefix
        self.services = services
        self.colorIndex = colorIndex
    }

    /// What to call it anywhere a human reads it. Custom name, else the clean prefix
    /// ("LARQ_" -> "LARQ") instead of the random suffix, else the raw name.
    var title: String {
        let c = displayName.trimmingCharacters(in: .whitespaces)
        if !c.isEmpty { return c }
        let p = matchPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "_- "))
        if !p.isEmpty { return p }
        return bluetoothName.isEmpty ? "Item" : bluetoothName
    }

    var serviceUUIDs: [CBUUID] { services.map(CBUUID.init(string:)) }
    var backgroundCapable: Bool { !services.isEmpty }
    var looksLikeLarq: Bool { matchPrefix.uppercased().hasPrefix("LARQ") }
    var color: Color { ItemPalette.color(colorIndex) }

    func matches(_ name: String) -> Bool {
        let p = matchPrefix.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return false }
        return name.range(of: p, options: [.caseInsensitive, .anchored]) != nil
    }

    // Tolerant decoding, so adding a field later never wipes saved items.
    private enum CodingKeys: String, CodingKey {
        case id, bluetoothName, displayName, matchPrefix, services, alertsEnabled, alertOnLeaveArea,
             notifyReturns, graceSeconds, areaRadius, holdConnection, disablePowerSaving, colorIndex
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        bluetoothName = try c.decodeIfPresent(String.self, forKey: .bluetoothName) ?? ""
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        matchPrefix = try c.decodeIfPresent(String.self, forKey: .matchPrefix) ?? bluetoothName
        services = try c.decodeIfPresent([String].self, forKey: .services) ?? []
        alertsEnabled = try c.decodeIfPresent(Bool.self, forKey: .alertsEnabled) ?? true
        alertOnLeaveArea = try c.decodeIfPresent(Bool.self, forKey: .alertOnLeaveArea) ?? true
        notifyReturns = try c.decodeIfPresent(Bool.self, forKey: .notifyReturns) ?? false
        graceSeconds = try c.decodeIfPresent(Double.self, forKey: .graceSeconds) ?? 180
        areaRadius = try c.decodeIfPresent(Double.self, forKey: .areaRadius) ?? 150
        holdConnection = try c.decodeIfPresent(Bool.self, forKey: .holdConnection) ?? false
        disablePowerSaving = try c.decodeIfPresent(Bool.self, forKey: .disablePowerSaving) ?? false
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
    }
}

/// Live, in-memory state for one item.
struct ItemLive: Equatable {
    var status: LinkStatus = .connecting
    var rssi: Int?
    /// When the rssi reading arrived, so the finder can tell live from stale.
    var rssiAt: Date?
    var lastSighting: Date?
    /// When it was last heard, once status is .lost.
    var lastLost: Date?
    var battery: Int?
    var isConnected = false
}

enum LinkStatus: String {
    case idle = "Not watching"
    case connecting = "Searching..."
    case connected = "With You"
    case lost = "LOST"
}

enum ItemPalette {
    static let colors: [Color] = [
        Color(red: 0.04, green: 0.45, blue: 0.85),
        Color(red: 0.95, green: 0.50, blue: 0.10),
        Color(red: 0.55, green: 0.30, blue: 0.85),
        Color(red: 0.15, green: 0.65, blue: 0.35),
        Color(red: 0.90, green: 0.25, blue: 0.45),
        Color(red: 0.10, green: 0.65, blue: 0.70),
    ]
    static func color(_ i: Int) -> Color { colors[((i % colors.count) + colors.count) % colors.count] }
}
