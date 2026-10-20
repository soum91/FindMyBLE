import SwiftUI
import MapKit
import CoreLocation
import CoreBluetooth
import UIKit

// Full-screen map with a persistent bottom sheet, Find My style.
struct ContentView: View {
    @ObservedObject var m = BLEMonitor.shared
    @ObservedObject var loc = LocationRecorder.shared
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var detent: PresentationDetent = .fraction(0.4)

    var body: some View {
        Map(position: $camera) {
            UserAnnotation()
            ForEach(m.items) { it in
                // The geofence you must cross before this item's left-behind alert fires.
                // Radius comes from the item so the ring follows the slider live.
                if it.alertOnLeaveArea, let a = loc.area[it.id] {
                    MapCircle(center: a.coordinate, radius: Geofence.clamp(it.areaRadius))
                        .foregroundStyle(it.color.opacity(0.10))
                        .stroke(it.color.opacity(0.55), lineWidth: 1.5)
                }
            }
            ForEach(m.items) { it in
                if let fix = loc.lastSeen[it.id] {
                    Annotation(it.title, coordinate: fix.coordinate, anchor: .bottom) {
                        ItemPin(color: it.color)
                    }
                }
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .onAppear { loc.requestPermission() }
        .sheet(isPresented: .constant(true)) {
            SheetRoot(focus: focus)
                .presentationDetents([.height(110), .fraction(0.4), .large], selection: $detent)
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.4)))
                .presentationCornerRadius(22)
                .interactiveDismissDisabled()
        }
    }

    /// Show the item's ring (or last-seen spot) on the map.
    private func focus(_ id: UUID) {
        guard let it = m.item(id) else { return }
        let center = loc.area[id]?.coordinate ?? loc.lastSeen[id]?.coordinate
        guard let center else {
            withAnimation { camera = .userLocation(fallback: .automatic) }
            return
        }
        let span = max(400, it.areaRadius * 3)
        withAnimation {
            camera = .region(MKCoordinateRegion(center: center, latitudinalMeters: span, longitudinalMeters: span))
        }
        detent = .fraction(0.4)
    }
}

// MARK: - Map pin

struct ItemPin: View {
    let color: Color
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(.white).frame(width: 46, height: 46).shadow(radius: 3)
                Circle().fill(color.gradient).frame(width: 38, height: 38)
                Image(systemName: "drop.fill").foregroundStyle(.white).font(.system(size: 18, weight: .semibold))
            }
            Triangle().fill(.white).frame(width: 12, height: 8).shadow(radius: 1)
        }
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: .init(x: r.minX, y: r.minY))
            p.addLine(to: .init(x: r.maxX, y: r.minY))
            p.addLine(to: .init(x: r.midX, y: r.maxY))
            p.closeSubpath()
        }
    }
}

struct ItemIcon: View {
    var color: Color = ItemPalette.color(0)
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            Circle().fill(color.gradient)
            Image(systemName: "drop.fill").foregroundStyle(.white).font(.system(size: size * 0.45, weight: .semibold))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Sheet with tabs

struct SheetRoot: View {
    let focus: (UUID) -> Void
    var body: some View {
        TabView {
            ItemsTab(focus: focus)
                .tabItem { Label("Items", systemImage: "circle.grid.2x2.fill") }
            MeTab()
                .tabItem { Label("Me", systemImage: "person.crop.circle.fill") }
        }
    }
}

// MARK: Items

struct ItemsTab: View {
    @ObservedObject var m = BLEMonitor.shared
    let focus: (UUID) -> Void
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                if m.items.isEmpty {
                    VStack(spacing: 10) {
                        ItemIcon(size: 56)
                        Text("No Items").font(.headline)
                        Text("Add your bottle or any Bluetooth device to get alerted when you leave it behind.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Add Item") { showAdd = true }.buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                } else {
                    ForEach(m.items) { it in
                        NavigationLink {
                            ItemDetail(id: it.id)
                        } label: {
                            ItemRow(id: it.id)
                        }
                        .simultaneousGesture(TapGesture().onEnded { focus(it.id) })
                    }
                    .onDelete { idx in idx.map { m.items[$0].id }.forEach(m.remove) }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Items")
            .toolbar {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
            .sheet(isPresented: $showAdd) { AddItemView() }
        }
    }
}

struct ItemRow: View {
    @ObservedObject var m = BLEMonitor.shared
    @ObservedObject var loc = LocationRecorder.shared
    @AppStorage(DistanceUnit.storageKey) private var unit: DistanceUnit = .localeDefault
    let id: UUID

    var body: some View {
        if let it = m.item(id) {
            HStack(spacing: 12) {
                ItemIcon(color: it.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(it.title).font(.headline)
                    StatusLine(id: id).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if let d = distanceText { Text(d).font(.subheadline).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 4)
        }
    }

    private var distanceText: String? {
        if m.state(id).status == .connected { return nil }
        guard let fix = loc.lastSeen[id], let me = loc.current else { return nil }
        let meters = me.distance(from: CLLocation(latitude: fix.lat, longitude: fix.lon))
        return unit.format(meters)
    }
}

struct StatusLine: View {
    @ObservedObject var m = BLEMonitor.shared
    let id: UUID
    var body: some View {
        let s = m.state(id)
        switch s.status {
        case .connected:
            Text("With You").foregroundStyle(.green)
        case .connecting:
            Text("Searching...")
        case .lost:
            if let t = s.lastLost {
                Text("Left Behind · \(t, style: .relative) ago").foregroundStyle(.red)
            } else {
                Text("Left Behind").foregroundStyle(.red)
            }
        case .idle:
            Text("Not tracking")
        }
    }
}

// MARK: Item detail

struct ItemDetail: View {
    @ObservedObject var m = BLEMonitor.shared
    @ObservedObject var loc = LocationRecorder.shared
    @AppStorage(DistanceUnit.storageKey) private var unit: DistanceUnit = .localeDefault
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var address: String?
    @State private var showNearby = false
    @State private var confirmRemove = false

    var body: some View {
        if let it = m.item(id) {
            content(it)
        } else {
            ContentUnavailableView("Item Removed", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func content(_ it: TrackedItem) -> some View {
        let s = m.state(id)
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    StatusLine(id: id).font(.subheadline)
                    if s.status != .connected, let a = address {
                        Text("Near \(a)").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }

            Section {
                HStack(spacing: 12) {
                    ActionCard(title: "Directions", icon: "car.fill",
                               subtitle: loc.lastSeen[id] == nil ? "No location" : "Last seen spot",
                               enabled: loc.lastSeen[id] != nil) { openInMaps(it) }
                    ActionCard(title: "Find Nearby", icon: "dot.radiowaves.left.and.right",
                               subtitle: s.status == .connected ? "In range" : "Listen for signal",
                               enabled: true) { showNearby = true }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if !it.backgroundCapable {
                Section {
                    Label("This item doesn't advertise a service ID, so iOS only lets FindMyBLE hear it while the app is open.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }

            Section {
                LabeledContent("Name") {
                    TextField(BLEMonitor.defaultPrefix(for: it.bluetoothName)
                                .trimmingCharacters(in: CharacterSet(charactersIn: "_- ")),
                              text: m.binding(id, \.displayName, default: ""))
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.done)
                }
                LabeledContent("Bluetooth name") {
                    Text(it.bluetoothName).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            } header: {
                Text("Display")
            } footer: {
                Text("Only changes what FindMyBLE shows, in the app and in alerts. The device's real Bluetooth name stays the same.")
            }

            Section {
                LabeledContent("Name starts with") {
                    TextField("LARQ_", text: m.binding(id, \.matchPrefix, default: ""))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("Matching")
            } footer: {
                Text(samePrefixWarning(it)
                     ?? "Any device advertising a name that starts with this counts as this item, so a rotating name suffix doesn't matter.")
            }

            Section {
                Toggle("Keep Connected", isOn: m.binding(id, \.holdConnection, default: false))
                if it.holdConnection {
                    LabeledContent("Link") { Text(s.isConnected ? "Connected" : "Reconnecting...") }
                    if let b = s.battery { LabeledContent("Battery") { Text("\(b)%") } }
                    if it.looksLikeLarq {
                        Toggle("Stop Cap Power-Saving", isOn: m.binding(id, \.disablePowerSaving, default: false))
                    }
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("Keeping a live connection usually stops a device from dropping off, and lets it report battery. A connected device stops advertising, so it shows as \"Connected\" in Add Item.")
            }

            Section {
                Toggle("Notify When Left Behind", isOn: m.binding(id, \.alertsEnabled, default: true))
                if it.alertsEnabled {
                    Toggle("Only When I Leave the Area", isOn: m.binding(id, \.alertOnLeaveArea, default: true))
                    if it.alertOnLeaveArea {
                        GeofenceSlider(radius: m.binding(id, \.areaRadius, default: 150))
                    } else {
                        Stepper("Alert after \(Int(it.graceSeconds / 60)) min",
                                value: m.binding(id, \.graceSeconds, default: 180), in: 60...1800, step: 60)
                    }
                    Toggle("Notify When Back", isOn: m.binding(id, \.notifyReturns, default: false))
                }
                if let t = s.lastSighting {
                    LabeledContent("Last heard") { Text("\(t, style: .relative) ago") }
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text(it.alertOnLeaveArea
                     ? "Alerts only when you walk out of this item's ring on the map. Bigger ring, fewer false alarms but a later alert. Needs location set to Always."
                     : "Alerts when the item hasn't been heard from for this long. Simple, but a device that sleeps its radio will cause false alarms.")
            }

            if let fix = loc.lastSeen[id] {
                Section("Last Seen") {
                    LabeledContent("Time", value: fix.date.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Accuracy", value: "about \(unit.format(max(fix.accuracy, 15)))")
                }
            }

            Section {
                Button("Remove This Item", role: .destructive) { confirmRemove = true }
            }
        }
        .navigationTitle(it.title)
        .task(id: loc.lastSeen[id]) { await geocode() }
        .sheet(isPresented: $showNearby) { FindNearbyView(id: id) }
        .confirmationDialog("Stop tracking \(it.title)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { dismiss(); m.remove(id) }
        }
    }

    private func samePrefixWarning(_ it: TrackedItem) -> String? {
        let p = it.matchPrefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard !p.isEmpty else { return "Empty prefix: nothing will match this item." }
        let clash = m.items.contains { o in
            guard o.id != it.id else { return false }
            let q = o.matchPrefix.trimmingCharacters(in: .whitespaces).lowercased()
            return !q.isEmpty && (q.hasPrefix(p) || p.hasPrefix(q))
        }
        return clash
            ? "Another item uses an overlapping prefix, so FindMyBLE can't always tell them apart by name. Keep Connected ties each item to its own device."
            : nil
    }

    private func geocode() async {
        guard let fix = loc.lastSeen[id] else { address = nil; return }
        let pm = try? await CLGeocoder()
            .reverseGeocodeLocation(CLLocation(latitude: fix.lat, longitude: fix.lon)).first
        address = [pm?.subThoroughfare, pm?.thoroughfare].compactMap { $0 }.joined(separator: " ")
            .nilIfEmpty ?? pm?.name
    }

    private func openInMaps(_ it: TrackedItem) {
        guard let fix = loc.lastSeen[id] else { return }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: fix.coordinate))
        item.name = "\(it.title) last seen"
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
}

struct ActionCard: View {
    let title: String, icon: String, subtitle: String, enabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(enabled ? Color.accentColor : .gray))
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: Find Nearby (signal strength, foreground only)

struct FindNearbyView: View {
    @ObservedObject var m = BLEMonitor.shared
    @Environment(\.dismiss) private var dismiss
    let id: UUID

    // Self-calibrating: the strongest signal seen this session becomes "here", everything
    // scales from there. This cap advertises weakly, so fixed dBm thresholds are useless.
    @State private var peak: Int = -100
    @State private var now = Date()
    private let clock = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    /// A reading older than this is stale (the device went quiet), not "far".
    private let freshWindow: TimeInterval = 8

    private var s: ItemLive { m.state(id) }

    var body: some View {
        ZStack {
            LinearGradient(colors: [(m.item(id)?.color ?? .blue), Color(red: 0.02, green: 0.1, blue: 0.3)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 30) {
                HStack {
                    Text(m.item(id)?.title ?? "Item").font(.headline)
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                }
                .foregroundStyle(.white)
                Spacer()
                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 2).frame(width: 290, height: 290)
                    Circle().fill(.white.opacity(fresh ? 0.9 : 0.25))
                        .frame(width: 290 * closeness, height: 290 * closeness)
                        .animation(.spring(duration: 0.6), value: closeness)
                }
                Text(label).font(.system(size: 38, weight: .bold)).foregroundStyle(.white)
                Text(detail).font(.subheadline).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(fresh
                     ? "Move around. The circle grows as you get closer."
                     : "Waiting to hear it. A LARQ cap sleeps to save battery, so give it a shake or open the lid.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
        .onReceive(clock) { t in
            now = t
            if let r = s.rssi, fresh, r > peak { peak = r }
        }
        .onAppear { m.beginFinding(id); if let r = s.rssi { peak = r } }
        .onDisappear { m.endFinding(id) }
    }

    private var fresh: Bool {
        guard let at = s.rssiAt else { return false }
        return now.timeIntervalSince(at) < freshWindow
    }

    /// 0.12 .. 1 scaled over a 25 dB window below the strongest signal seen.
    private var closeness: CGFloat {
        guard fresh, let r = s.rssi else { return 0.12 }
        let span = 25.0
        let ratio = (Double(r) - (Double(peak) - span)) / span
        return CGFloat(min(1, max(0.12, ratio)))
    }

    private var label: String {
        guard fresh else { return "Listening" }
        switch closeness {
        case 0.75...: return "Here"
        case 0.45...: return "Nearby"
        default: return "Keep Looking"
        }
    }

    private var detail: String {
        guard let r = s.rssi else { return "No signal yet" }
        if !fresh { return "Last signal \(Int(now.timeIntervalSince(s.rssiAt ?? now)))s ago" }
        return "\(r) dBm"
    }
}

// MARK: Add Item (scan)

struct AddItemView: View {
    @ObservedObject var m = BLEMonitor.shared
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(filtered) { d in
                        Button {
                            m.add(d)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(d.name).foregroundStyle(.primary)
                                    if let t = trackedAs(d) {
                                        Text("Matches \(t)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if d.connected {
                                    Text("Connected").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    SignalBars(rssi: d.rssi)
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Nearby Devices")
                        Spacer()
                        if m.isScanning { ProgressView() }
                    }
                } footer: {
                    Text("Don't see your LARQ? Open the lid or give the bottle a shake to wake the cap, and close the LARQ app, which can hold the cap's only connection.")
                }
            }
            .searchable(text: $filter, prompt: "Filter (e.g. LARQ)")
            .navigationTitle("Add Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { m.startScan() }
            .onDisappear { m.stopScan() }
            .overlay {
                if m.btState != .poweredOn {
                    ContentUnavailableView("Bluetooth Is Off", systemImage: "antenna.radiowaves.left.and.right.slash")
                }
            }
        }
    }

    private func trackedAs(_ d: BLEMonitor.Device) -> String? {
        m.items.first { $0.matches(d.name) }?.title
    }

    private var filtered: [BLEMonitor.Device] {
        filter.isEmpty ? m.devices : m.devices.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }
}

struct SignalBars: View {
    let rssi: Int
    var body: some View {
        let level = rssi > -60 ? 4 : rssi > -70 ? 3 : rssi > -80 ? 2 : 1
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i <= level ? Color.accentColor : Color.gray.opacity(0.3))
                    .frame(width: 4, height: CGFloat(4 + i * 3))
            }
        }
    }
}

// MARK: Me

struct MeTab: View {
    @ObservedObject var m = BLEMonitor.shared
    @ObservedObject var loc = LocationRecorder.shared
    @ObservedObject var places = TrustedPlaces.shared
    @State private var showAddPlace = false
    @State private var newName = ""
    @State private var renaming: Place?
    @State private var renameText = ""
    @AppStorage(DistanceUnit.storageKey) private var unit: DistanceUnit = .localeDefault

    var body: some View {
        NavigationStack {
            List {
                Section("Permissions") {
                    LabeledContent("Bluetooth", value: m.btState == .poweredOn ? "On" : "Off")
                    LabeledContent("Location", value: locText)
                    if loc.authStatus != .authorizedAlways {
                        Button("Set Location to Always") {
                            if loc.authStatus == .denied || loc.authStatus == .restricted {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            } else {
                                loc.requestPermission()
                            }
                        }
                    }
                }
                Section {
                    ForEach(places.places) { p in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: "mappin.circle.fill").foregroundStyle(.tint)
                                Text(p.name)
                                Spacer()
                            }
                            GeofenceSlider(title: "Radius", radius: Binding(
                                get: { places.places.first { $0.id == p.id }?.radius ?? p.radius },
                                set: { places.setRadius(p, $0) }))
                                .font(.subheadline)
                            Picker("", selection: Binding(
                                get: { p.mode },
                                set: { places.setMode(p, $0) })) {
                                Text("Remind me").tag(PlaceMode.remind)
                                Text("Ignore").tag(PlaceMode.ignore)
                            }
                            .pickerStyle(.segmented)
                        }
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") {
                                renameText = p.name
                                renaming = p
                            }
                        }
                    }
                    .onDelete { idx in idx.map { places.places[$0] }.forEach(places.remove) }
                    Button {
                        newName = ""
                        showAddPlace = true
                    } label: {
                        Label("Add Current Location", systemImage: "plus")
                    }
                    .disabled(loc.current == nil)
                } header: {
                    Text("Trusted Locations")
                } footer: {
                    Text("Remind me: get a nudge if you leave this place without the item (set home to this). Ignore: never alert here, you leave it on purpose. Needs location Always.")
                }

                Section {
                    Picker("Distance", selection: $unit) {
                        ForEach(DistanceUnit.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Units")
                } footer: {
                    Text("Only changes how distances are shown. Small rings (under about 100 m or 330 ft) are allowed, but iOS geofencing is coarse, so expect the alert to fire a bit further out than the ring.")
                }

                Section {
                    Text("Don't force-quit FindMyBLE from the app switcher, or iOS stops waking it up for Bluetooth events. After a reboot, open it once.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("Keep It Working") }
            }
            .navigationTitle("Me")
            .alert("Name this place", isPresented: $showAddPlace) {
                TextField("Home, Work...", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Add") {
                    if let here = loc.current { places.add(name: newName, at: here, mode: .remind) }
                }
            } message: {
                Text("Saves where you are now as a trusted spot.")
            }
            .alert("Rename place", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    if let p = renaming { places.rename(p, renameText) }
                    renaming = nil
                }
            }
        }
    }

    private var locText: String {
        switch loc.authStatus {
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "While Using"
        case .denied, .restricted: return "Denied"
        default: return "Not Set"
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
