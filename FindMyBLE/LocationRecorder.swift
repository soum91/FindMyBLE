import Foundation
import CoreLocation
import UIKit

/// Grabs the phone's location at the moment the device drops, so you know where you left it.
/// The phone was within BLE range (roughly 10 to 30 m) when the link died, so this is
/// effectively the bottle's last known spot.
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

    @Published var lastSeen: Fix?
    /// The live geofence, so the map can draw the ring you must cross to get an alert.
    @Published var area: Area?
    @Published var authStatus: CLAuthorizationStatus = .notDetermined

    /// Called when the phone leaves the area where the item was last heard. Background-safe:
    /// region monitoring relaunches the app to deliver this.
    var onLeftArea: (() -> Void)?
    /// Called when the phone leaves a trusted place (confirmed by a real fix).
    var onLeftPlace: ((Place) -> Void)?

    private let manager = CLLocationManager()
    private let storeKey = "lastSeenFix"
    private let regionID = "item-area"
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var pending = false
    private var pendingArmRadius: Double?

    // The item geofence we armed, kept so an exit can be sanity-checked against a real fix.
    private var regionCenter: CLLocationCoordinate2D?
    private var regionRadius: Double = 150
    // Trusted-place regions, keyed by region id, so their exits can be verified and routed.
    private var placeRegions: [String: Place] = [:]

    // One exit being confirmed at a time.
    private var verifyingExit = false
    private var pendingExitID: String?
    private var pendingExitCenter: CLLocationCoordinate2D?
    private var pendingExitRadius: Double = 150

    /// How far beyond the radius, with a trustworthy fix, before we believe you actually left.
    private let exitMargin: Double = 120
    private let maxTrustedAccuracy: Double = 65

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        authStatus = manager.authorizationStatus
        if let d = UserDefaults.standard.data(forKey: storeKey),
           let f = try? JSONDecoder().decode(Fix.self, from: d) {
            lastSeen = f
        }
    }

    /// The phone's most recent fix, for "distance from you".
    var current: CLLocation? { manager.location }

    /// "Always" is needed so a fix can be taken while the app is in the background,
    /// which is exactly when you walk away from the bottle.
    func requestPermission() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    /// Called on disconnect. Saves the cached fix immediately, then asks for a fresh one.
    func recordNow() {
        if let loc = manager.location, Date().timeIntervalSince(loc.timestamp) < 120 {
            save(loc)
        }
        guard manager.authorizationStatus == .authorizedAlways
                || manager.authorizationStatus == .authorizedWhenInUse else { return }
        pending = true
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "lastSeenFix") { [weak self] in
            self?.endBG()
        }
        manager.requestLocation()
    }

    // MARK: Geofence around the item's current spot

    /// (Re)centre a geofence on where we are now. Call this whenever we have BLE contact,
    /// so "the area the item is in" tracks the item while it's with you.
    func armGeofence(radius: Double) {
        guard authStatus == .authorizedAlways else { return }
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        if let loc = manager.location, Date().timeIntervalSince(loc.timestamp) < 120 {
            startRegion(center: loc.coordinate, radius: radius)
        } else {
            pendingArmRadius = radius
            manager.requestLocation()
        }
    }

    /// Change the size of the live geofence without moving it. If nothing is armed yet,
    /// arm one here at the new size.
    func resizeGeofence(radius: Double) {
        if let c = regionCenter, area != nil {
            startRegion(center: c, radius: radius)
        } else {
            armGeofence(radius: radius)
        }
    }

    func disarmGeofence() {
        pendingArmRadius = nil
        area = nil
        for r in manager.monitoredRegions where r.identifier == regionID {
            manager.stopMonitoring(for: r)
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
            let clamped = min(max(p.radius, 50), manager.maximumRegionMonitoringDistance)
            let region = CLCircularRegion(center: p.coordinate, radius: clamped, identifier: id)
            region.notifyOnEntry = false
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
            placeRegions[id] = p
        }
    }

    private func startRegion(center: CLLocationCoordinate2D, radius: Double) {
        disarmGeofence()
        let clamped = min(max(radius, 50), manager.maximumRegionMonitoringDistance)
        regionCenter = center
        regionRadius = clamped
        area = Area(lat: center.latitude, lon: center.longitude, radius: clamped)
        let region = CLCircularRegion(center: center, radius: clamped, identifier: regionID)
        region.notifyOnEntry = false
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
    }

    private func save(_ loc: CLLocation) {
        let f = Fix(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                    accuracy: loc.horizontalAccuracy, date: loc.timestamp)
        lastSeen = f
        if let d = try? JSONEncoder().encode(f) { UserDefaults.standard.set(d, forKey: storeKey) }
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
        // Step up from When In Use to Always right after the first grant.
        if m.authorizationStatus == .authorizedWhenInUse { m.requestAlwaysAuthorization() }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        if pending, let loc = locs.last { save(loc) }
        pending = false
        if let r = pendingArmRadius, let loc = locs.last {
            pendingArmRadius = nil
            startRegion(center: loc.coordinate, radius: r)
        }
        if verifyingExit, let loc = locs.last { resolveExit(with: loc) }
        endBG()
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        pending = false
        // Couldn't get a fix to confirm an exit: don't alert on a guess.
        if verifyingExit {
            verifyingExit = false
            if pendingExitID == regionID, let c = regionCenter { startRegion(center: c, radius: regionRadius) }
            pendingExitID = nil
        }
        endBG()
    }

    func locationManager(_ m: CLLocationManager, didExitRegion region: CLRegion) {
        // Don't trust the raw exit. Indoors the fix jumps hundreds of metres while you stand
        // still, so confirm with a fresh high-accuracy fix before believing you actually left.
        if region.identifier == regionID {
            beginExitVerify(id: regionID, center: regionCenter, radius: regionRadius)
        } else if let p = placeRegions[region.identifier] {
            beginExitVerify(id: region.identifier, center: p.coordinate, radius: p.radius)
        }
    }

    private func beginExitVerify(id: String, center: CLLocationCoordinate2D?, radius: Double) {
        guard let center else { return }
        pendingExitID = id
        pendingExitCenter = center
        pendingExitRadius = radius
        verifyingExit = true
        manager.desiredAccuracy = kCLLocationAccuracyBest
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "exitCheck") { [weak self] in self?.endBG() }
        manager.requestLocation()
    }

    private func resolveExit(with loc: CLLocation) {
        verifyingExit = false
        guard let center = pendingExitCenter, let id = pendingExitID else { return }
        let d = loc.distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude))
        let trustworthy = loc.horizontalAccuracy > 0 && loc.horizontalAccuracy <= maxTrustedAccuracy
        if trustworthy && d > pendingExitRadius + exitMargin {
            if id == regionID { onLeftArea?() }
            else if let p = placeRegions[id] { onLeftPlace?(p) }
        } else if id == regionID {
            startRegion(center: center, radius: pendingExitRadius)  // drift: re-arm item geofence
        }
        // Place regions stay monitored by iOS; nothing to re-arm.
        pendingExitID = nil
        pendingExitCenter = nil
    }
}
