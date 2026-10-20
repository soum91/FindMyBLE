import Foundation
import CoreLocation
import UIKit

/// Per item: where the phone was when the item was last heard (its "last seen" spot), and a
/// geofence around that spot that you must cross before a left-behind alert can fire.
final class LocationRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationRecorder()

    struct Fix: Codable, Equatable {
        let lat: Double
        let lon: Double
        let accuracy: Double
        let date: Date
        var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    }

    struct Area: Equatable {
        let lat: Double
        let lon: Double
        let radius: Double
        var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    }

    @Published var lastSeen: [UUID: Fix] = [:]
    /// Live geofence per item, so the map can draw each ring you must cross to get an alert.
    @Published var area: [UUID: Area] = [:]
    @Published var authStatus: CLAuthorizationStatus = .notDetermined

    /// Phone left an item's area. Background-safe: region monitoring relaunches the app.
    var onLeftArea: ((UUID) -> Void)?
    /// Phone left a trusted place (confirmed by a real fix).
    var onLeftPlace: ((Place) -> Void)?

    private let manager = CLLocationManager()
    private let storeKey = "lastSeenFixes.v2"
    private let legacyStoreKey = "lastSeenFix"
    private let legacyRegionID = "item-area"
    private let itemPrefix = "item-"
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    /// Items waiting on a fresh fix to record their last-seen spot.
    private var pendingRecord: Set<UUID> = []
    /// Items waiting on a fix to centre a new geofence, with the radius to use.
    private var pendingArm: [UUID: Double] = [:]
    /// Trusted-place regions, keyed by region id, so their exits can be verified and routed.
    private var placeRegions: [String: Place] = [:]
    /// Region exits waiting on a trustworthy fix before we believe them.
    private var pendingExits: [String: (center: CLLocationCoordinate2D, radius: Double)] = [:]

    /// How far beyond the radius, with a trustworthy fix, before we believe you actually left.
    /// Scales down for small rings (so a 10 m ring isn't really a 130 m one), but never below
    /// the fix's own error, so GPS wobble indoors can't fake an exit.
    private let exitMargin: Double = 120
    private func margin(for radius: Double, accuracy: Double) -> Double {
        max(min(exitMargin, max(20, radius)), accuracy)
    }
    private let maxTrustedAccuracy: Double = 65

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        authStatus = manager.authorizationStatus
        if let d = UserDefaults.standard.data(forKey: storeKey),
           let f = try? JSONDecoder().decode([String: Fix].self, from: d) {
            lastSeen = Dictionary(uniqueKeysWithValues: f.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
        }
        // After a background relaunch the regions are still monitored by iOS but our memory is
        // empty. Rebuild the rings from what iOS reports so exits can still be verified.
        for r in manager.monitoredRegions {
            guard let c = r as? CLCircularRegion else { continue }
            if c.identifier == legacyRegionID {
                manager.stopMonitoring(for: c)   // single-item build's region, replaced per item
            } else if let id = itemID(c.identifier) {
                area[id] = Area(lat: c.center.latitude, lon: c.center.longitude, radius: c.radius)
            }
        }
    }

    /// The phone's most recent fix, for "distance from you".
    var current: CLLocation? { manager.location }

    func requestPermission() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    /// The single-item build kept one fix. Hand it to the migrated item.
    func adoptLegacyFix(for id: UUID) {
        guard lastSeen[id] == nil,
              let d = UserDefaults.standard.data(forKey: legacyStoreKey),
              let f = try? JSONDecoder().decode(Fix.self, from: d) else { return }
        lastSeen[id] = f
        persist()
    }

    /// Item was just heard (or just dropped). Save the cached fix now, then ask for a fresh one.
    func recordNow(for id: UUID) {
        if let loc = manager.location, Date().timeIntervalSince(loc.timestamp) < 120 {
            save(loc, for: [id])
        }
        guard manager.authorizationStatus == .authorizedAlways
                || manager.authorizationStatus == .authorizedWhenInUse else { return }
        pendingRecord.insert(id)
        requestFix(named: "lastSeenFix")
    }

    func forget(_ id: UUID) {
        disarmGeofence(for: id)
        pendingRecord.remove(id)
        lastSeen[id] = nil
        persist()
    }

    // MARK: Item geofences

    /// (Re)centre an item's geofence on where we are now. Called while we have BLE contact,
    /// so "the area the item is in" follows the item while it's with you.
    func armGeofence(for id: UUID, radius: Double) {
        guard authStatus == .authorizedAlways,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        if let loc = manager.location, Date().timeIntervalSince(loc.timestamp) < 120 {
            startRegion(id, center: loc.coordinate, radius: radius)
        } else {
            pendingArm[id] = radius
            requestFix(named: "armGeofence")
        }
    }

    /// Change an item's geofence size without moving it. Arms one here if none is live.
    func resizeGeofence(for id: UUID, radius: Double) {
        if let a = area[id] {
            startRegion(id, center: a.coordinate, radius: radius)
        } else {
            armGeofence(for: id, radius: radius)
        }
    }

    func disarmGeofence(for id: UUID) {
        pendingArm[id] = nil
        area[id] = nil
        let rid = regionID(id)
        pendingExits[rid] = nil
        for r in manager.monitoredRegions where r.identifier == rid { manager.stopMonitoring(for: r) }
    }

    /// Drop rings for items that no longer exist.
    func pruneGeofences(keeping ids: Set<UUID>) {
        for r in manager.monitoredRegions {
            if let id = itemID(r.identifier), !ids.contains(id) {
                manager.stopMonitoring(for: r)
                area[id] = nil
            }
        }
    }

    /// Monitor a region around each trusted place so leaving one can fire a reminder.
    func syncPlaceRegions(_ places: [Place]) {
        guard authStatus == .authorizedAlways,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        for r in manager.monitoredRegions where r.identifier.hasPrefix("place-") {
            manager.stopMonitoring(for: r)
        }
        placeRegions.removeAll()
        for p in places {
            let id = "place-\(p.id.uuidString)"
            let region = CLCircularRegion(center: p.coordinate, radius: clamp(p.radius), identifier: id)
            region.notifyOnEntry = false
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
            placeRegions[id] = p
        }
    }

    private func startRegion(_ id: UUID, center: CLLocationCoordinate2D, radius: Double) {
        let rid = regionID(id)
        for r in manager.monitoredRegions where r.identifier == rid { manager.stopMonitoring(for: r) }
        pendingArm[id] = nil
        let r = clamp(radius)
        area[id] = Area(lat: center.latitude, lon: center.longitude, radius: r)
        let region = CLCircularRegion(center: center, radius: r, identifier: rid)
        region.notifyOnEntry = false
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
    }

    private func clamp(_ r: Double) -> Double { min(max(r, Geofence.range.lowerBound), manager.maximumRegionMonitoringDistance) }
    private func regionID(_ id: UUID) -> String { itemPrefix + id.uuidString }
    private func itemID(_ regionID: String) -> UUID? {
        guard regionID.hasPrefix(itemPrefix) else { return nil }
        return UUID(uuidString: String(regionID.dropFirst(itemPrefix.count)))
    }

    // MARK: Fixes

    private func requestFix(named: String) {
        if bgTask == .invalid {
            bgTask = UIApplication.shared.beginBackgroundTask(withName: named) { [weak self] in self?.endBG() }
        }
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.requestLocation()
    }

    private func save(_ loc: CLLocation, for ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let f = Fix(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                    accuracy: loc.horizontalAccuracy, date: loc.timestamp)
        for id in ids { lastSeen[id] = f }
        persist()
    }

    private func persist() {
        let out = Dictionary(uniqueKeysWithValues: lastSeen.map { ($0.key.uuidString, $0.value) })
        if let d = try? JSONEncoder().encode(out) { UserDefaults.standard.set(d, forKey: storeKey) }
    }

    private func endBG() {
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
        bgTask = .invalid
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        authStatus = m.authorizationStatus
        if m.authorizationStatus == .authorizedAlways {
            syncPlaceRegions(TrustedPlaces.shared.places)
        }
        if m.authorizationStatus == .authorizedWhenInUse { m.requestAlwaysAuthorization() }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { endBG(); return }
        save(loc, for: pendingRecord)
        pendingRecord.removeAll()
        let arms = pendingArm
        pendingArm.removeAll()
        for (id, r) in arms { startRegion(id, center: loc.coordinate, radius: r) }
        if !pendingExits.isEmpty { resolveExits(with: loc) }
        endBG()
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        pendingRecord.removeAll()
        // Couldn't confirm an exit: don't alert on a guess. Re-arm item rings where they were.
        let exits = pendingExits
        pendingExits.removeAll()
        for (rid, e) in exits {
            if let id = itemID(rid) { startRegion(id, center: e.center, radius: e.radius) }
        }
        endBG()
    }

    func locationManager(_ m: CLLocationManager, didExitRegion region: CLRegion) {
        // Don't trust the raw exit. Indoors the fix jumps hundreds of metres while you stand
        // still, so confirm with a fresh high-accuracy fix before believing you actually left.
        // Centre comes from the region itself, so this works after a cold background relaunch.
        guard let c = region as? CLCircularRegion else { return }
        if let p = placeRegions[c.identifier] {
            pendingExits[c.identifier] = (p.coordinate, p.radius)
        } else if itemID(c.identifier) != nil {
            pendingExits[c.identifier] = (c.center, c.radius)
        } else {
            return
        }
        requestFix(named: "exitCheck")
    }

    private func resolveExits(with loc: CLLocation) {
        let exits = pendingExits
        pendingExits.removeAll()
        let trustworthy = loc.horizontalAccuracy > 0 && loc.horizontalAccuracy <= maxTrustedAccuracy
        for (rid, e) in exits {
            let d = loc.distance(from: CLLocation(latitude: e.center.latitude, longitude: e.center.longitude))
            let left = trustworthy && d > e.radius + margin(for: e.radius, accuracy: loc.horizontalAccuracy)
            if let id = itemID(rid) {
                if left { onLeftArea?(id) }
                else { startRegion(id, center: e.center, radius: e.radius) }  // drift: re-arm
            } else if left, let p = placeRegions[rid] {
                onLeftPlace?(p)
            }
            // Place regions stay monitored by iOS; nothing to re-arm.
        }
    }
}
