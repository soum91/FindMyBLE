import WidgetKit
import SwiftUI
import AppIntents

// The widget only draws what the app saved into the App Group. iOS doesn't let widgets use
// Bluetooth or run in the background, so the link to the item is held by the app itself.

@main
struct FindMyBLEWidgets: WidgetBundle {
    var body: some Widget {
        ItemWidget()
        WaterWidget()
    }
}

// MARK: - Item picker

struct ItemEntity: AppEntity {
    let id: String
    let title: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Item"
    static var defaultQuery = ItemQuery()
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct ItemQuery: EntityQuery {
    private func all() -> [ItemEntity] {
        SharedSnapshot.load().items.map { ItemEntity(id: $0.id.uuidString, title: $0.title) }
    }
    func entities(for identifiers: [String]) async throws -> [ItemEntity] {
        all().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [ItemEntity] { all() }
    func defaultResult() async -> ItemEntity? { all().first }
}

struct SelectItemIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Item"
    static var description = IntentDescription("Pick which item this widget shows.")
    @Parameter(title: "Item") var item: ItemEntity?
    init() {}
}

// MARK: - Item widget

struct ItemEntry: TimelineEntry {
    let date: Date
    let item: SharedItem?
    let water: WaterLog
    let unit: DistanceUnit
    let shared: Bool
    var mapLight: UIImage? = nil
    var mapDark: UIImage? = nil
}

struct ItemProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ItemEntry {
        ItemEntry(date: .now, item: .preview, water: WaterLog(), unit: .localeDefault, shared: true)
    }

    func snapshot(for config: SelectItemIntent, in context: Context) async -> ItemEntry {
        context.isPreview && SharedSnapshot.load().items.isEmpty
            ? placeholder(in: context)
            : await entry(config, context)
    }

    func timeline(for config: SelectItemIntent, in context: Context) async -> Timeline<ItemEntry> {
        // The app pushes reloads when something changes; this is just a safety refresh.
        Timeline(entries: [await entry(config, context)], policy: .after(.now.addingTimeInterval(30 * 60)))
    }

    private func entry(_ config: SelectItemIntent, _ context: Context) async -> ItemEntry {
        let snap = SharedSnapshot.load()
        let item = snap.items.first { $0.id.uuidString == config.item?.id } ?? snap.items.first
        var e = ItemEntry(date: .now, item: item, water: WaterLog.load(), unit: snap.distanceUnit, shared: AppGroup.isShared)
        // Pictures the app already rendered. Nothing heavy happens here, so the timeline returns at once.
        if context.family == .systemMedium, let item {
            e.mapLight = AppGroup.readData(MapFiles.name(item.id, dark: false)).flatMap(UIImage.init(data:))
            e.mapDark = AppGroup.readData(MapFiles.name(item.id, dark: true)).flatMap(UIImage.init(data:))
        }
        return e
    }
}

struct ItemWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKinds.item, intent: SelectItemIntent.self, provider: ItemProvider()) { e in
            ItemWidgetView(e: e)
        }
        .configurationDisplayName("Item")
        .description("Where your item is, its battery and today's water.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
        .contentMarginsDisabled()
    }
}

struct ItemWidgetView: View {
    let e: ItemEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if !e.shared {
                Notice(text: "Reinstall FindMyBLE with app extensions kept on so the widget can see it.")
            } else if let it = e.item {
                switch family {
                case .systemMedium: medium(it)
                case .accessoryRectangular: rectangular(it)
                case .accessoryCircular: circular(it)
                case .accessoryInline: inline(it)
                default: small(it)
                }
            } else {
                Notice(text: "Add an item in FindMyBLE.")
            }
        }
        .containerBackground(for: .widget) { Color(.systemBackground) }
        .widgetURL(URL(string: "findmyble://item/\(e.item?.id.uuidString ?? "")"))
    }

    // Small: the item at a glance.
    private func small(_ it: SharedItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                ItemBadge(kind: it.icon, colorIndex: it.colorIndex, size: 36)
                Spacer()
                if let b = it.battery { BatteryLabel(level: b, stale: !it.isConnected).font(.caption2) }
            }
            Spacer(minLength: 2)
            Text(it.title).font(.headline).lineLimit(1)
            StatusText(it: it).font(.caption.weight(.semibold))
            SeenLine(it: it).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(14)
    }

    // Medium: map of the last-seen spot, details, and the water button.
    private func medium(_ it: SharedItem) -> some View {
        HStack(spacing: 0) {
            ZStack {
                if let img = scheme == .dark ? (e.mapDark ?? e.mapLight) : (e.mapLight ?? e.mapDark) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    ItemPalette.color(it.colorIndex).opacity(0.15)
                }
                VStack(spacing: 0) {
                    ZStack {
                        Circle().fill(.white).frame(width: 34, height: 34).shadow(radius: 2)
                        ItemBadge(kind: it.icon, colorIndex: it.colorIndex, size: 28)
                    }
                    PinTip().fill(.white).frame(width: 9, height: 6)
                }
                .offset(y: -17)   // the tip sits on the spot
            }
            .frame(width: 155)
            .clipped()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(it.title).font(.headline).lineLimit(1)
                    Spacer(minLength: 4)
                    if let b = it.battery { BatteryLabel(level: b, stale: !it.isConnected).font(.caption2) }
                }
                StatusText(it: it).font(.caption.weight(.semibold))
                SeenLine(it: it).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 2)
                HStack(spacing: 6) {
                    Gauge(value: e.water.progress) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .tint(.blue)
                    Text(e.unit.volume(e.water.total())).font(.caption2.weight(.semibold)).monospacedDigit()
                    Button(intent: LogWaterIntent()) {
                        Image(systemName: "plus").font(.caption.weight(.bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .buttonBorderShape(.circle)
                }
            }
            .padding(12)
        }
    }

    private func rectangular(_ it: SharedItem) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(it.title).font(.headline).lineLimit(1)
                if let b = it.battery { Text("\(b)%").font(.caption).monospacedDigit() }
            }
            StatusText(it: it, plain: true).font(.caption)
            SeenLine(it: it).font(.caption2).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func circular(_ it: SharedItem) -> some View {
        ZStack {
            AccessoryWidgetBackground()
            if let b = it.battery {
                Gauge(value: Double(b), in: 0...100) {
                    ItemGlyph(kind: it.icon).frame(width: 14, height: 14)
                } currentValueLabel: {
                    Text("\(b)").monospacedDigit()
                }
                .gaugeStyle(.accessoryCircular)
            } else {
                ItemGlyph(kind: it.icon).frame(width: 26, height: 26)
            }
        }
    }

    private func inline(_ it: SharedItem) -> some View {
        let state: String
        if it.isConnected || it.status == .connected { state = "With you" }
        else if it.status == .lost { state = "Left behind" }
        else { state = "Last seen" }
        let batt = it.battery.map { " · \($0)%" } ?? ""
        return Text(it.title + " · " + state + batt)
    }
}

struct StatusText: View {
    let it: SharedItem
    var plain = false
    var body: some View {
        if it.isConnected || it.status == .connected {
            Text("With You").foregroundStyle(plain ? .primary : Color.green)
        } else if it.status == .lost {
            Text("Left Behind").foregroundStyle(plain ? .primary : Color.red)
        } else {
            Text("Not heard just now").foregroundStyle(.secondary)
        }
    }
}

/// "Near 12 Elm St · 5 min ago". Times tick on their own, no reload needed.
struct SeenLine: View {
    let it: SharedItem
    var body: some View {
        if it.isConnected || it.status == .connected {
            if let p = it.place { Text(p) } else { Text("In range") }
        } else if let t = it.lastSighting {
            if let p = it.place {
                Text("Near \(p), \(t, style: .relative) ago")
            } else {
                Text("Heard \(t, style: .relative) ago")
            }
        } else {
            Text("Not heard yet")
        }
    }
}

struct PinTip: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: .init(x: r.minX, y: r.minY))
            p.addLine(to: .init(x: r.maxX, y: r.minY))
            p.addLine(to: .init(x: r.midX, y: r.maxY))
            p.closeSubpath()
        }
    }
}

struct Notice: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
    }
}

extension SharedItem {
    static let preview = SharedItem(id: UUID(), title: "LARQ", icon: .bottle, colorIndex: 0, status: .connected,
                                    isConnected: true, lastSighting: .now, battery: 82, batteryAt: .now,
                                    place: "Home", lat: nil, lon: nil, fixAt: nil)
}

// MARK: - Water widget

struct WaterEntryT: TimelineEntry {
    let date: Date
    let water: WaterLog
    let unit: DistanceUnit
}

struct WaterProvider: TimelineProvider {
    func placeholder(in context: Context) -> WaterEntryT {
        var w = WaterLog(); w.entries = [WaterEntry(date: .now, ml: 1250)]
        return WaterEntryT(date: .now, water: w, unit: .localeDefault)
    }
    func getSnapshot(in context: Context, completion: @escaping (WaterEntryT) -> Void) {
        completion(entry())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WaterEntryT>) -> Void) {
        // Redraw at midnight so the count resets to zero for the new day.
        let midnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86_400))
        completion(Timeline(entries: [entry()], policy: .after(midnight)))
    }
    private func entry() -> WaterEntryT {
        WaterEntryT(date: .now, water: WaterLog.load(), unit: SharedSnapshot.load().distanceUnit)
    }
}

struct WaterWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.water, provider: WaterProvider()) { e in
            WaterWidgetView(e: e)
        }
        .configurationDisplayName("Water")
        .description("Today's water. Tap + to log a glass.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

struct WaterWidgetView: View {
    let e: WaterEntryT
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                Gauge(value: e.water.progress) {
                    ItemGlyph(kind: .bottle).frame(width: 12, height: 12)
                } currentValueLabel: {
                    Text("\(Int(e.water.progress * 100))%")
                }
                .gaugeStyle(.accessoryCircularCapacity)
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    Text("Water").font(.headline)
                    Text("\(e.unit.volume(e.water.total())) of \(e.unit.volume(e.water.goal))").font(.caption)
                    Gauge(value: e.water.progress) { EmptyView() }.gaugeStyle(.accessoryLinearCapacity)
                }
            default:
                small
            }
        }
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }

    private var small: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.blue.opacity(0.18), lineWidth: 8)
                Circle().trim(from: 0, to: e.water.progress)
                    .stroke(Color.blue.gradient, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(e.unit.volume(e.water.total())).font(.headline).monospacedDigit()
                        .minimumScaleFactor(0.7).lineLimit(1)
                    Text("of \(e.unit.volume(e.water.goal))").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
            }
            Button(intent: LogWaterIntent()) {
                Label("+\(e.unit.volume(e.water.glass))", systemImage: "plus")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
    }
}
