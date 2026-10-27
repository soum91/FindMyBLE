import SwiftUI
import WidgetKit

// Read-only Lock Screen status, built exactly like DewPoint's 1x1 temperature widget,
// the one Lock Screen widget that renders on iOS 27 beta 4 with sideloaded builds:
// static configuration, cached data only (no network in the timeline), no buttons,
// no accessory background. Tapping it opens the app.
struct FindMyBLELockEntry: TimelineEntry {
    var date: Date
    var item: SharedItem?
    var water: Double
    var icon: String { item?.status == .lost ? "exclamationmark.triangle.fill" : "drop.fill" }
    var short: String { item.map { $0.isConnected ? "Near" : ($0.status == .lost ? "LOST" : "Away") } ?? "--" }
    var title: String { item?.title ?? "FindMyBLE" }
    var headline: String { item.map { $0.isConnected ? "With you" : ($0.status == .lost ? "Left behind" : $0.status.rawValue) } ?? "Open FindMyBLE" }
    var detail: String {
        if let i = item, !i.isConnected, let seen = i.lastSighting { return "Seen \(seen.formatted(date: .omitted, time: .shortened))" }
        return "Water \(Int(water)) ml"
    }
    static func make() -> FindMyBLELockEntry { .init(date: .now, item: SharedSnapshot.load().items.first, water: WaterLog.load().total()) }
}

struct FindMyBLELockProvider: TimelineProvider {
    func placeholder(in context: Context) -> FindMyBLELockEntry { FindMyBLELockEntry.make() }
    func getSnapshot(in context: Context, completion: @escaping (FindMyBLELockEntry) -> Void) { completion(FindMyBLELockEntry.make()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<FindMyBLELockEntry>) -> Void) {
        completion(Timeline(entries: [FindMyBLELockEntry.make()], policy: .after(.now.addingTimeInterval(900))))
    }
}

struct FindMyBLELockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FindMyBLELockStatusV1", provider: FindMyBLELockProvider()) { entry in
            FindMyBLELockView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Item status")
        .description("Whether your item is with you, plus water today. Tap to open FindMyBLE.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

struct FindMyBLELockView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FindMyBLELockEntry

    var body: some View {
        Group {
            if family == .accessoryCircular {
                VStack(spacing: 1) {
                    Image(systemName: entry.icon)
                        .font(.system(size: 16, weight: .semibold))
                    Text(entry.short)
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: entry.icon)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title).font(.caption2).lineLimit(1)
                        Text(entry.headline).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                        if !entry.detail.isEmpty {
                            Text(entry.detail).font(.caption2).lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}
