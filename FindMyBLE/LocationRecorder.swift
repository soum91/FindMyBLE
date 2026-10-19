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

    @Published var lastSeen: Fix?
    @Published var authStatus: CLAuthorizationStatus = .notDetermined

    /// Called when the phone leaves the area where the item was last heard. Background-safe:
    /// region monitoring relaunches the app to deliver this.
    var onLeftArea: (() -> Void)?

    private let manager = CLLocationManager()
    private let storeKey = "lastSeenFix"
    private let regionID = "item-area"
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var pending = false
    private var pendingArmRadius: Double?

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

    func disarmGeofence() {
        pendingArmRadius = nil
        for r in manager.monitoredRegions where r.identifier == regionID {
            manager.stopMonitoring(for: r)
        }
    }

    private func startRegion(center: CLLocationCoordinate2D, radius: Double) {
        disarmGeofence()
        let clamped = min(max(radius, 50), manager.maximumRegionMonitoringDistance)
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
        endBG()
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        pending = false
        endBG()
    }

    func locationManager(_ m: CLLocationManager, didExitRegion region: CLRegion) {
        if region.identifier == regionID { onLeftArea?() }
    }
}
