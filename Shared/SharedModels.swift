import Foundation
import SwiftUI
import WidgetKit

// Everything the app and the widget both need. The widget never talks Bluetooth or GPS: the app
// writes a small snapshot into the App Group and the widget only draws it.

enum LinkStatus: String, Codable {
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

// MARK: - Icons

enum ItemIconKind: String, Codable, CaseIterable, Identifiable {
    case bottle, tag, bag, keys, headphones, laptop
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bottle: "Bottle"
        case .tag: "Tag"
        case .bag: "Bag"
        case .keys: "Keys"
        case .headphones: "Headphones"
        case .laptop: "Laptop"
        }
    }
    /// SF Symbol for everything except the bottle, which is drawn (see BottleShape).
    var symbol: String? {
        switch self {
        case .bottle: nil
        case .tag: "tag.fill"
        case .bag: "bag.fill"
        case .keys: "key.fill"
        case .headphones: "headphones"
        case .laptop: "laptopcomputer"
        }
    }
}

/// A tall water bottle with a carry loop, cap and seam, same as the app icon. Drawn rather than an
/// SF Symbol so it looks identical on every iOS version and in the widget.
private func unitRect(_ r: CGRect, _ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
    CGRect(x: r.minX + x0 * r.width, y: r.minY + y0 * r.height, width: (x1 - x0) * r.width, height: (y1 - y0) * r.height)
}

struct BottleShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addRoundedRect(in: unitRect(r, 0.365, 0.065, 0.635, 0.24), cornerSize: .init(width: 0.06 * r.width, height: 0.06 * r.height), style: .continuous)   // cap
        p.addRoundedRect(in: unitRect(r, 0.35, 0.20, 0.65, 0.99), cornerSize: .init(width: 0.09 * r.width, height: 0.09 * r.height), style: .continuous)     // body
        return p
    }
}

/// Carry loop on the cap. Fill with eoFill so the middle stays open.
struct BottleLoop: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addRoundedRect(in: unitRect(r, 0.425, 0.0, 0.575, 0.10), cornerSize: .init(width: 0.045 * r.width, height: 0.045 * r.height))
        p.addRoundedRect(in: unitRect(r, 0.455, 0.03, 0.545, 0.075), cornerSize: .init(width: 0.02 * r.width, height: 0.02 * r.height))
        return p
    }
}

/// Seam under the cap and a highlight down the body, drawn in the badge colour.
struct BottleDetail: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addRect(unitRect(r, 0.35, 0.232, 0.65, 0.25))
        p.addRoundedRect(in: unitRect(r, 0.395, 0.33, 0.44, 0.88), cornerSize: .init(width: 0.022 * r.width, height: 0.022 * r.height))
        return p
    }
}

/// The white glyph for an item, sized to its frame.
struct ItemGlyph: View {
    let kind: ItemIconKind
    var tint: Color = .blue
    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            Group {
                if let sym = kind.symbol {
                    Image(systemName: sym)
                        .font(.system(size: s * 0.8, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    ZStack {
                        BottleLoop().fill(.white, style: FillStyle(eoFill: true))
                        BottleShape().fill(.white)
                        BottleDetail().fill(tint.opacity(0.4))
                    }
                    .frame(width: s, height: s)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

/// Coloured circle with the item's glyph. Used in the app list, map pins and the widget.
struct ItemBadge: View {
    let kind: ItemIconKind
    let colorIndex: Int
    var size: CGFloat = 40
    var body: some View {
        let c = ItemPalette.color(colorIndex)
        ZStack {
            Circle().fill(c.gradient)
            ItemGlyph(kind: kind, tint: c)
                .frame(width: size * (kind == .bottle ? 0.68 : 0.5), height: size * (kind == .bottle ? 0.68 : 0.5))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Units

/// Display unit. Everything is stored metric; this only changes what you see.
enum DistanceUnit: String, CaseIterable, Identifiable {
    case metric, imperial
    var id: String { rawValue }
    var label: String { self == .metric ? "Metric" : "Imperial" }

    static let storageKey = "distanceUnit"
    static var localeDefault: DistanceUnit { Locale.current.measurementSystem == .us ? .imperial : .metric }

    func format(_ meters: Double) -> String {
        switch self {
        case .metric:
            if meters < 1000 { return "\(Int(meters.rounded())) m" }
            return String(format: meters < 10_000 ? "%.1f km" : "%.0f km", meters / 1000)
        case .imperial:
            let ft = meters * 3.28084
            if ft < 1000 { return "\(Int(ft.rounded())) ft" }
            let mi = meters / 1609.344
            return String(format: mi < 10 ? "%.2f mi" : "%.1f mi", mi)
        }
    }

    /// Water. Millilitres / litres, or US fluid ounces.
    func volume(_ ml: Double) -> String {
        switch self {
        case .metric:
            if ml < 1000 { return "\(Int(ml.rounded())) ml" }
            return String(format: "%.2f L", ml / 1000).replacingOccurrences(of: "0 L", with: " L")
        case .imperial:
            return "\(Int((ml / 29.5735).rounded())) oz"
        }
    }

    /// Round a metre value to a step that looks clean in this unit.
    func snap(_ meters: Double) -> Double {
        switch self {
        case .metric:
            let step: Double = meters < 50 ? 5 : meters < 200 ? 10 : meters < 500 ? 25 : 50
            return (meters / step).rounded() * step
        case .imperial:
            let ft = meters * 3.28084
            let step: Double = ft < 200 ? 5 : ft < 1000 ? 25 : 100
            return (ft / step).rounded() * step / 3.28084
        }
    }
}

// MARK: - Snapshot the widget draws

struct SharedItem: Codable, Hashable, Identifiable {
    var id: UUID
    var title: String
    var icon: ItemIconKind
    var colorIndex: Int
    var status: LinkStatus
    var isConnected: Bool
    var lastSighting: Date?
    /// Last battery reading. Kept after the link drops so the widget still has a number.
    var battery: Int?
    var batteryAt: Date?
    /// Street-level name of the last-seen spot, reverse-geocoded by the app (no extra GPS).
    var place: String?
    var lat: Double?
    var lon: Double?
    var fixAt: Date?
}

struct SharedSnapshot: Codable {
    var items: [SharedItem] = []
    var unit: String = DistanceUnit.localeDefault.rawValue
    var updated: Date = .distantPast

    static let file = "snapshot.json"
    static func load() -> SharedSnapshot { AppGroup.read(SharedSnapshot.self, file) ?? SharedSnapshot() }
    func save() { AppGroup.write(self, Self.file) }
    var distanceUnit: DistanceUnit { DistanceUnit(rawValue: unit) ?? .localeDefault }
}

enum WidgetKinds {
    static let item = "FindMyBLE.item"
    static let water = "FindMyBLE.water"
}

// MARK: - Water log

struct WaterEntry: Codable, Hashable {
    var date: Date
    var ml: Double
}

/// Logged by hand from the app or the widget. Shared through the App Group.
struct WaterLog: Codable {
    var entries: [WaterEntry] = []
    var goal: Double = 2000
    /// One tap of "+" adds this much.
    var glass: Double = 250

    static let file = "water.json"
    static func load() -> WaterLog { AppGroup.read(WaterLog.self, file) ?? WaterLog() }

    func save() {
        var copy = self
        let cutoff = Calendar.current.date(byAdding: .day, value: -60, to: .now) ?? .distantPast
        copy.entries.removeAll { $0.date < cutoff }
        AppGroup.write(copy, Self.file)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.water)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.item)
    }

    func total(on day: Date = .now) -> Double {
        let cal = Calendar.current
        return entries.filter { cal.isDate($0.date, inSameDayAs: day) }.reduce(0) { $0 + $1.ml }
    }

    var progress: Double { goal > 0 ? min(total() / goal, 1) : 0 }

    static func add(_ ml: Double? = nil) {
        var log = load()
        log.entries.append(WaterEntry(date: .now, ml: ml ?? log.glass))
        log.save()
    }

    /// Removes today's most recent entry.
    static func undoLast() {
        var log = load()
        if let i = log.entries.lastIndex(where: { Calendar.current.isDateInToday($0.date) }) {
            log.entries.remove(at: i)
            log.save()
        }
    }
}

// MARK: - Battery label

struct BatteryLabel: View {
    let level: Int
    /// Older reading (link is down): drawn dimmer so it doesn't pass for live.
    var stale = false

    private var symbol: String {
        switch level {
        case 88...: "battery.100percent"
        case 63..<88: "battery.75percent"
        case 38..<63: "battery.50percent"
        case 13..<38: "battery.25percent"
        default: "battery.0percent"
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(level <= 20 ? .red : .primary)
            Text("\(level)%").monospacedDigit()
        }
        .opacity(stale ? 0.55 : 1)
        .accessibilityLabel("Battery \(level) percent\(stale ? ", last reading" : "")")
    }
}
