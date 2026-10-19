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
            if let fix = loc.lastSeen, m.watchedName != nil, m.status != .connected {
                Annotation(m.watchedName ?? "Item", coordinate: fix.coordinate, anchor: .bottom) {
                    ItemPin(status: m.status)
                }
                MapCircle(center: fix.coordinate, radius: max(fix.accuracy, 15))
                    .foregroundStyle(.blue.opacity(0.12))
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .onAppear { loc.requestPermission() }
        .sheet(isPresented: .constant(true)) {
            SheetRoot(focus: focusOnItem)
                .presentationDetents([.height(110), .fraction(0.4), .large], selection: $detent)
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.4)))
                .presentationCornerRadius(22)
                .interactiveDismissDisabled()
        }
    }

    private func focusOnItem() {
        guard let fix = loc.lastSeen, m.status != .connected else {
            withAnimation { camera = .userLocation(fallback: .automatic) }
            return
        }
        withAnimation {
            camera = .region(MKCoordinateRegion(center: fix.coordinate,
                                                latitudinalMeters: 400, longitudinalMeters: 400))
        }
        detent = .fraction(0.4)
    }
}

// MARK: - Map pin

struct ItemPin: View {
    let status: BLEMonitor.LinkStatus
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(.white).frame(width: 46, height: 46).shadow(radius: 3)
                Circle().fill(LinearGradient(colors: [Color(red: 0.2, green: 0.88, blue: 0.82),
                                                      Color(red: 0.04, green: 0.36, blue: 0.78)],
                                             startPoint: .top, endPoint: .bottom))
                    .frame(width: 38, height: 38)
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
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(red: 0.2, green: 0.88, blue: 0.82),
                                                  Color(red: 0.04, green: 0.36, blue: 0.78)],
                                         startPoint: .top, endPoint: .bottom))
            Image(systemName: "drop.fill").foregroundStyle(.white).font(.system(size: size * 0.45, weight: .semibold))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Sheet with tabs

struct SheetRoot: View {
    let focus: () -> Void
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
    @ObservedObject var loc = LocationRecorder.shared
    let focus: () -> Void
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                if let name = m.watchedName {
                    NavigationLink {
                        ItemDetail()
                    } label: {
                        ItemRow(name: name)
                    }
                    .simultaneousGesture(TapGesture().onEnded { focus() })
                } else {
                    VStack(spacing: 10) {
                        ItemIcon(size: 56)
                        Text("No Items").font(.headline)
                        Text("Add your bottle or any Bluetooth device to get alerted when you leave it behind.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Add Item") { showAdd = true }.buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
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
    let name: String

    var body: some View {
        HStack(spacing: 12) {
            ItemIcon()
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                StatusLine().font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if let d = distanceText { Text(d).font(.subheadline).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4)
    }

    private var distanceText: String? {
        if m.status == .connected { return nil }
        guard let fix = loc.lastSeen, let me = loc.current else { return nil }
        let meters = me.distance(from: CLLocation(latitude: fix.lat, longitude: fix.lon))
        return Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

struct StatusLine: View {
    @ObservedObject var m = BLEMonitor.shared
    var body: some View {
        switch m.status {
        case .connected:
            Text("With You").foregroundStyle(.green)
        case .connecting:
            Text("Searching...")
        case .lost:
            if let t = m.lastLost {
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
    @Environment(\.dismiss) private var dismiss
    @State private var address: String?
    @State private var showNearby = false
    @State private var confirmRemove = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    StatusLine().font(.subheadline)
                    if m.status != .connected, let a = address {
                        Text("Near \(a)").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }

            Section {
                HStack(spacing: 12) {
                    ActionCard(title: "Directions", icon: "car.fill",
                               subtitle: loc.lastSeen == nil ? "No location" : "Last seen spot",
                               enabled: loc.lastSeen != nil) { openInMaps() }
                    ActionCard(title: "Find Nearby", icon: "dot.radiowaves.left.and.right",
                               subtitle: m.status == .connected ? "In range" : "Out of range",
                               enabled: m.status == .connected) { showNearby = true }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if !m.backgroundCapable {
                Section {
                    Label("This item doesn't advertise a service ID, so iOS only lets FindMyBLE hear it while the app is open.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }

            Section {
                Toggle("Notify When Left Behind", isOn: $m.alertsEnabled)
                Stepper("Alert after \(Int(m.graceSeconds / 60)) min", value: $m.graceSeconds, in: 60...1800, step: 60)
                if let t = m.lastSighting {
                    LabeledContent("Last heard") { Text("\(t, style: .relative) ago") }
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Alerts when the item hasn't been heard from for this long. Lower is faster but more false alarms.")
            }

            if let fix = loc.lastSeen {
                Section("Last Seen") {
                    LabeledContent("Time", value: fix.date.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Accuracy", value: "about \(Int(max(fix.accuracy, 15))) m")
                }
            }

            Section {
                Button("Remove This Item", role: .destructive) { confirmRemove = true }
            }
        }
        .navigationTitle(m.watchedName ?? "Item")
        .task(id: loc.lastSeen) { await geocode() }
        .sheet(isPresented: $showNearby) { FindNearbyView() }
        .confirmationDialog("Stop tracking this item?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { m.unwatch(); dismiss() }
        }
    }

    private func geocode() async {
        guard let fix = loc.lastSeen else { address = nil; return }
        let pm = try? await CLGeocoder()
            .reverseGeocodeLocation(CLLocation(latitude: fix.lat, longitude: fix.lon)).first
        address = [pm?.subThoroughfare, pm?.thoroughfare].compactMap { $0 }.joined(separator: " ")
            .nilIfEmpty ?? pm?.name
    }

    private func openInMaps() {
        guard let fix = loc.lastSeen else { return }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: fix.coordinate))
        item.name = "\(m.watchedName ?? "Item") last seen"
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

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.04, green: 0.36, blue: 0.78),
                                    Color(red: 0.02, green: 0.15, blue: 0.4)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 30) {
                HStack {
                    Text(m.watchedName ?? "Item").font(.headline)
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                }
                .foregroundStyle(.white)
                Spacer()
                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 2).frame(width: 280, height: 280)
                    Circle().fill(.white.opacity(0.9))
                        .frame(width: 280 * closeness, height: 280 * closeness)
                        .animation(.spring(duration: 0.6), value: closeness)
                }
                Text(label).font(.system(size: 40, weight: .bold)).foregroundStyle(.white)
                Text(m.rssi.map { "\($0) dBm" } ?? "No signal").foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text("Walk around. The circle grows as you get closer.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.7))
            }
            .padding()
        }
    }

    /// Maps roughly -95 dBm (far) .. -45 dBm (on top of it) to 0.15 .. 1
    private var closeness: CGFloat {
        guard let r = m.rssi else { return 0.1 }
        return min(1, max(0.15, CGFloat(r + 95) / 50))
    }

    private var label: String {
        guard let r = m.rssi else { return "Searching" }
        switch r {
        case (-55)...: return "Here"
        case (-70)...: return "Nearby"
        default: return "Far"
        }
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
                            m.watch(d)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.tint)
                                Text(d.name).foregroundStyle(.primary)
                                Spacer()
                                SignalBars(rssi: d.rssi)
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
                    Text("Close the LARQ app before adding, it can hold the bottle's only connection.")
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
                    Text("Don't force-quit FindMyBLE from the app switcher, or iOS stops waking it up for Bluetooth events. After a reboot, open it once.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("Keep It Working") }
            }
            .navigationTitle("Me")
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
