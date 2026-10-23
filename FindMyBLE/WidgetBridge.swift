import Foundation
import CoreLocation
import WidgetKit
import Combine
import UIKit
import MapKit

/// Feeds the widget. Writes a small snapshot into the App Group whenever something the widget
/// shows changes, and asks WidgetKit to redraw.
///
/// Battery: nothing here turns on GPS. The "location" is the last-seen fix the app already took,
/// and the street name comes from one reverse-geocode per new spot (a network call, not GPS).
/// Widget reloads from the background count against a daily budget, so only real changes
/// (status, connection, a 5% battery step, a new spot) trigger one right away; everything else
/// waits at least 15 minutes. Times on the widget tick by themselves without reloads.
final class WidgetBridge {
    static let shared = WidgetBridge()

    private let geocoder = CLGeocoder()
    private var places: [UUID: (lat: Double, lon: Double, name: String)] = [:]
    /// Where each item's saved map picture is centred, so it's only re-rendered when the spot moves.
    private var mapStamps: [UUID: (lat: Double, lon: Double)] = [:]
    private let mapStampsKey = "widgetMapStamps"
    private var renderingMap = false
    private let placesKey = "widgetPlaceNames"
    private var geocoding = false
    private var pending: DispatchWorkItem?
    private var lastSignature: [UUID: String] = [:]
    private var lastReload = Date.distantPast
    private var bag: Set<AnyCancellable> = []

    private init() {
        for (k, v) in UserDefaults.standard.dictionary(forKey: mapStampsKey) as? [String: [Double]] ?? [:] {
            if let id = UUID(uuidString: k), v.count == 2 { mapStamps[id] = (v[0], v[1]) }
        }
        if let saved = UserDefaults.standard.dictionary(forKey: placesKey) as? [String: [String: Any]] {
            for (k, v) in saved {
                guard let id = UUID(uuidString: k), let lat = v["lat"] as? Double,
                      let lon = v["lon"] as? Double, let name = v["name"] as? String else { continue }
                places[id] = (lat, lon, name)
            }
        }
    }

    /// Call once at launch.
    func start() {
        let m = BLEMonitor.shared, loc = LocationRecorder.shared
        m.$items.sink { [weak self] _ in self?.schedule() }.store(in: &bag)
        m.$live.sink { [weak self] _ in self?.schedule() }.store(in: &bag)
        m.$lastBattery.sink { [weak self] _ in self?.schedule() }.store(in: &bag)
        loc.$lastSeen.sink { [weak self] _ in self?.schedule() }.store(in: &bag)
        UserDefaults.standard.publisher(for: \.distanceUnit).sink { [weak self] _ in
            self?.schedule(force: true)
        }.store(in: &bag)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.publish(force: true) }.store(in: &bag)
    }

    /// Coalesce bursts (a chatty advertiser updates live state many times a second).
    private func schedule(force: Bool = false) {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.publish(force: force) }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    private func publish(force: Bool = false) {
        let m = BLEMonitor.shared, loc = LocationRecorder.shared
        var snap = SharedSnapshot()
        snap.unit = UserDefaults.standard.string(forKey: DistanceUnit.storageKey) ?? DistanceUnit.localeDefault.rawValue
        snap.updated = .now
        snap.items = m.items.map { it in
            let s = m.state(it.id)
            let fix = loc.lastSeen[it.id]
            let batt = s.battery.map { BatteryReading(level: $0, at: .now) } ?? m.lastBattery[it.id]
            return SharedItem(id: it.id, title: it.title, icon: it.iconKind, colorIndex: it.colorIndex,
                              status: s.status, isConnected: s.isConnected, lastSighting: s.lastSighting,
                              battery: batt?.level, batteryAt: batt?.at,
                              place: fix.flatMap { placeName(for: it.id, near: $0) },
                              lat: fix?.lat, lon: fix?.lon, fixAt: fix?.date)
        }
        snap.save()

        // Reload only for changes worth a redraw; the widget's clocks tick on their own.
        var sig: [UUID: String] = [:]
        for i in snap.items {
            let battStep = i.battery.map { $0 / 5 } ?? -1
            sig[i.id] = "\(i.title)|\(i.icon)|\(i.colorIndex)|\(i.status)|\(i.isConnected)|\(battStep)|\(i.place ?? "")|\(Int((i.lat ?? 0) * 5000))|\(Int((i.lon ?? 0) * 5000))"
        }
        let changed = sig != lastSignature
        let foreground = UIApplication.shared.applicationState == .active
        if changed || force || (foreground && Date().timeIntervalSince(lastReload) > 60)
            || Date().timeIntervalSince(lastReload) > 900 {
            lastSignature = sig
            lastReload = .now
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.item)
        }
        geocodeNext()
        renderMapNext()
    }

    // MARK: Map pictures for the widget

    /// One item at a time: render its last-seen spot (light and dark) and hand it to the widget.
    /// Done here because MapKit is too heavy for the widget extension's memory limit.
    private func renderMapNext() {
        guard !renderingMap else { return }
        let loc = LocationRecorder.shared
        let ids = Set(BLEMonitor.shared.items.map(\.id))
        guard let (id, fix) = loc.lastSeen.first(where: { id, fix in
            guard ids.contains(id) else { return false }
            guard let st = mapStamps[id] else { return true }
            return CLLocation(latitude: st.lat, longitude: st.lon)
                .distance(from: CLLocation(latitude: fix.lat, longitude: fix.lon)) > 25
        }) else { return }
        renderingMap = true
        let center = CLLocationCoordinate2D(latitude: fix.lat, longitude: fix.lon)
        Task { @MainActor in
            let light = await Self.snapshot(center, dark: false)
            let dark = await Self.snapshot(center, dark: true)
            self.renderingMap = false
            guard let light, let dark else { return }   // offline or suspended: retry on the next update
            AppGroup.writeData(light, MapFiles.name(id, dark: false))
            AppGroup.writeData(dark, MapFiles.name(id, dark: true))
            self.mapStamps[id] = (fix.lat, fix.lon)
            self.saveMapStamps()
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.item)
            self.renderMapNext()
        }
    }

    /// Small square JPEG centred on the spot. The widget draws the pin over the centre.
    private static func snapshot(_ center: CLLocationCoordinate2D, dark: Bool) async -> Data? {
        let o = MKMapSnapshotter.Options()
        o.region = MKCoordinateRegion(center: center, latitudinalMeters: 350, longitudinalMeters: 350)
        o.size = CGSize(width: 170, height: 170)
        o.scale = 2
        o.pointOfInterestFilter = .excludingAll
        o.traitCollection = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let shot: MKMapSnapshotter.Snapshot? = await withCheckedContinuation { cont in
            MKMapSnapshotter(options: o).start(with: .main) { s, _ in cont.resume(returning: s) }
        }
        return shot?.image.jpegData(compressionQuality: 0.8)
    }

    private func saveMapStamps() {
        var out: [String: [Double]] = [:]
        for (k, v) in mapStamps { out[k.uuidString] = [v.lat, v.lon] }
        UserDefaults.standard.set(out, forKey: mapStampsKey)
    }

    /// Cached street name if the fix is within ~40 m of the spot we already named.
    private func placeName(for id: UUID, near fix: LocationRecorder.Fix) -> String? {
        guard let p = places[id] else { return nil }
        let d = CLLocation(latitude: p.lat, longitude: p.lon).distance(from: CLLocation(latitude: fix.lat, longitude: fix.lon))
        return d < 40 ? p.name : nil
    }

    /// One reverse-geocode at a time (Apple rate-limits these), only for spots without a name yet.
    private func geocodeNext() {
        guard !geocoding else { return }
        let loc = LocationRecorder.shared
        guard let (id, fix) = loc.lastSeen.first(where: { placeName(for: $0.key, near: $0.value) == nil }) else { return }
        geocoding = true
        geocoder.reverseGeocodeLocation(CLLocation(latitude: fix.lat, longitude: fix.lon)) { [weak self] pms, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.geocoding = false
                let pm = pms?.first
                let street = [pm?.subThoroughfare, pm?.thoroughfare].compactMap { $0 }.joined(separator: " ")
                let name = street.isEmpty ? (pm?.name ?? pm?.locality) : street
                guard let name else { return }   // offline: try again on the next update
                self.places[id] = (fix.lat, fix.lon, name)
                self.savePlaces()
                self.schedule()
            }
        }
    }

    private func savePlaces() {
        var out: [String: [String: Any]] = [:]
        for (k, v) in places { out[k.uuidString] = ["lat": v.lat, "lon": v.lon, "name": v.name] }
        UserDefaults.standard.set(out, forKey: placesKey)
    }

    func forget(_ id: UUID) {
        places[id] = nil
        savePlaces()
        mapStamps[id] = nil
        saveMapStamps()
        AppGroup.remove(MapFiles.name(id, dark: false))
        AppGroup.remove(MapFiles.name(id, dark: true))
    }
}

extension UserDefaults {
    /// KVO hook so the widget follows the Units setting. The name must match the defaults key.
    @objc dynamic var distanceUnit: String? { string(forKey: DistanceUnit.storageKey) }
}
