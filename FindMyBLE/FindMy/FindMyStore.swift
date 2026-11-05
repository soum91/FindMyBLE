import Foundation
import CoreLocation
import BackgroundTasks
import UserNotifications
import UIKit

// MARK: - Where I've been (a short trail)

/// A few hours of my own positions, so that when iCloud reports a device's position from earlier
/// I can tell whether I was standing next to it back then.
final class MovementMonitor: NSObject, CLLocationManagerDelegate {
    static let shared = MovementMonitor()

    struct Crumb: Codable { let t: Double; let lat: Double; let lon: Double; let acc: Double }

    private let manager = CLLocationManager()
    private(set) var trail: [Crumb] = []
    private var waiters: [CheckedContinuation<CLLocation?, Never>] = []
    private let key = "fmTrail"

    private override init() {
        super.init()
        if let d = UserDefaults.standard.data(forKey: key),
           let t = try? JSONDecoder().decode([Crumb].self, from: d) { trail = t }
        manager.delegate = self
    }

    /// Visits and big moves wake the app even after iOS has closed it. Needs location Always.
    func start() {
        manager.startMonitoringVisits()
        manager.startMonitoringSignificantLocationChanges()
    }

    func add(_ l: CLLocation) {
        guard l.horizontalAccuracy >= 0, l.horizontalAccuracy < 300 else { return }
        let t = l.timestamp.timeIntervalSince1970
        if let last = trail.last, t - last.t < 45,
           CLLocation(latitude: last.lat, longitude: last.lon).distance(from: l) < 40 { return }
        trail.append(Crumb(t: t, lat: l.coordinate.latitude, lon: l.coordinate.longitude, acc: l.horizontalAccuracy))
        let cutoff = Date().addingTimeInterval(-36 * 3600).timeIntervalSince1970
        trail.removeAll { $0.t < cutoff }
        if trail.count > 400 { trail.removeFirst(trail.count - 400) }
        if let d = try? JSONEncoder().encode(trail) { UserDefaults.standard.set(d, forKey: key) }
    }

    /// Was I within `radius` metres of `coord` at about `date` (within `window` seconds)?
    func wasNear(_ coord: CLLocationCoordinate2D, at date: Date, window: TimeInterval = 40 * 60, radius: Double) -> Bool {
        let target = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let t = date.timeIntervalSince1970
        return trail.contains { c in
            abs(c.t - t) <= window &&
            CLLocation(latitude: c.lat, longitude: c.lon).distance(from: target) <= max(radius, c.acc)
        }
    }

    /// A position for right now, from the cache if it's fresh, else asks GPS once.
    func currentFix() async -> CLLocation? {
        if let l = manager.location, abs(l.timestamp.timeIntervalSinceNow) < 90,
           l.horizontalAccuracy > 0, l.horizontalAccuracy <= 150 {
            add(l)
            return l
        }
        return await withCheckedContinuation { cont in
            waiters.append(cont)
            if waiters.count == 1 {
                manager.requestLocation()
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                    guard let self else { return }
                    self.flush(self.manager.location)
                }
            }
        }
    }

    private func flush(_ l: CLLocation?) {
        let w = waiters
        waiters = []
        if let l { add(l) }
        for c in w { c.resume(returning: l) }
    }

    // MARK: CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        if waiters.isEmpty {
            // Significant change: remember it and look at the devices.
            add(l)
            Task { @MainActor in FindMyStore.shared.requestCheck("moved") }
        } else {
            flush(l)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        flush(manager.location)
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let c = CLLocation(coordinate: visit.coordinate, altitude: 0,
                           horizontalAccuracy: max(visit.horizontalAccuracy, 20), verticalAccuracy: -1,
                           timestamp: visit.departureDate == .distantFuture ? visit.arrivalDate : visit.departureDate)
        add(c)
        Task { @MainActor in FindMyStore.shared.requestCheck("visit", force: true) }
    }
}

// MARK: - Store

@MainActor
final class FindMyStore: ObservableObject {
    static let shared = FindMyStore()

    struct Watch: Codable, Equatable {
        var enabled = false
        /// Alert once the device is this far from me (metres).
        var threshold: Double = 150
        /// Also alert for a device that normally stays put (a Mac at home). Off: only devices that travel with me.
        var always = false
    }

    struct Obs: Codable { let lat: Double; let lon: Double; let t: Double }

    @Published private(set) var devices: [FMDevice] = []
    @Published private(set) var signedIn = false
    @Published private(set) var refreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var expired = false
    @Published private(set) var watch: [String: Watch] = [:]

    /// When each device last moved while I was next to it.
    private var carried: [String: Date] = [:]
    private var alerted: [String: Date] = [:]
    private var lastObs: [String: Obs] = [:]
    private var lastCheck = Date.distantPast
    private var checking = false
    private let client = FindMyClient.shared
    private let defaults = UserDefaults.standard

    private init() {
        devices = load([FMDevice].self, "fmDevices") ?? []
        watch = load([String: Watch].self, "fmWatch") ?? [:]
        // Older builds watched every Apple device by default and saved that on any tweak.
        // Reset once so nothing alerts until it's turned on by hand; the LARQ bottle is unaffected.
        if !defaults.bool(forKey: "fmWatchOptIn") {
            watch = [:]
            save(watch, "fmWatch")
            defaults.set(true, forKey: "fmWatchOptIn")
        }
        carried = load([String: Date].self, "fmCarried") ?? [:]
        alerted = load([String: Date].self, "fmAlerted") ?? [:]
        lastObs = load([String: Obs].self, "fmObs") ?? [:]
        lastRefresh = defaults.object(forKey: "fmLastRefresh") as? Date
        Task { signedIn = await client.hasSession }
    }

    private func load<T: Decodable>(_ t: T.Type, _ key: String) -> T? {
        guard let d = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(t, from: d)
    }

    private func save<T: Encodable>(_ v: T, _ key: String) {
        if let d = try? JSONEncoder().encode(v) { defaults.set(d, forKey: key) }
    }

    func start() {
        MovementMonitor.shared.start()
        FindMyBackground.schedule()
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            Task { @MainActor in FindMyStore.shared.requestCheck("app opened") }
        }
    }

    // MARK: Sign in / out

    /// Called by the sign-in web view with the cookies it has. True once iCloud accepts them.
    func signIn(cookies: [HTTPCookie]) async -> Bool {
        await client.adopt(cookies)
        do {
            try await client.validate()
            signedIn = true
            lastError = nil
            FindMyLog.log("Signed in")
            await refresh(polls: 4)
            return true
        } catch {
            FindMyLog.log("Sign-in check failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Native sign-in, step 1. The password is kept in the Keychain on this phone for silent re-sign-in.
    func login(appleID: String, password: String) async throws -> FMLoginResult {
        let r = try await client.login(appleID: appleID, password: password)
        let id = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(id, forKey: "fmAppleID")
        FMKeychain.set(id, password)
        if case .signedIn = r { await didSignIn() }
        return r
    }

    func resendCodes() async -> [FMPhone] { await client.twoFactorOptions() }

    func textCode(phoneID: Int) async throws { try await client.textCode(phoneID: phoneID) }

    func submitCode(_ code: String, phoneID: Int?) async throws {
        try await client.submitCode(code, phoneID: phoneID)
        await didSignIn()
    }

    private func didSignIn() async {
        signedIn = true
        lastError = nil
        FindMyLog.log("Signed in")
        await refresh(polls: 4)
    }

    func signOut() {
        Task {
            await client.signOut()
            signedIn = false
            devices = []
            save(devices, "fmDevices")
            BatteryHandoff.publishSnapshot()
        }
    }

    // MARK: Watch settings

    func setting(_ id: String) -> Watch { watch[id] ?? Watch() }

    func update(_ id: String, _ change: (inout Watch) -> Void) {
        var w = setting(id)
        change(&w)
        watch[id] = w
        save(watch, "fmWatch")
    }

    // MARK: Refresh

    func refresh(polls: Int = 3, userAsked: Bool = false) async {
        guard signedIn, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let d = try await client.devices(polls: polls)
            apply(d)
            lastError = nil
        } catch FMError.expired {
            if await client.silentRelogin(userAsked: userAsked), let d = try? await client.devices(polls: polls) {
                apply(d)
                lastError = nil
                return
            }
            // Keep the account; the next allowed renewal (or a pull to refresh) picks it back up.
            expired = true
            lastError = "iCloud session expired. Tap Renew session. Apple emails you about each renewal."
            FindMyLog.log("Session expired")
        } catch {
            lastError = error.localizedDescription
            FindMyLog.log("Refresh failed: \(error.localizedDescription)")
        }
    }

    private func apply(_ d: [FMDevice]) {
        expired = false
        devices = d
        lastRefresh = Date()
        defaults.set(lastRefresh, forKey: "fmLastRefresh")
        save(d, "fmDevices")
        BatteryHandoff.publishSnapshot()
    }

    // MARK: Left-behind check

    func requestCheck(_ reason: String, force: Bool = false) {
        Task { await check(reason, force: force) }
    }

    /// Looks at where my devices are and where I am, and warns about any I seem to have left.
    func check(_ reason: String, force: Bool = false) async {
        guard signedIn, !checking else { return }
        // Each check asks iCloud to locate every device; keep it to every 15 min for routine
        // triggers. Leaving a place passes force.
        if !force, Date().timeIntervalSince(lastCheck) < 15 * 60 { return }
        checking = true
        lastCheck = Date()
        var bg = UIBackgroundTaskIdentifier.invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "findMyCheck") {
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
        }
        defer {
            checking = false
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
        }
        FindMyLog.log("Check (\(reason))")

        let foreground = UIApplication.shared.applicationState == .active
        guard let fix = await MovementMonitor.shared.currentFix() else {
            FindMyLog.log("Check skipped: no location fix (is Location set to Always?)")
            return
        }
        // Positions the bottle logic already recorded are good trail points too.
        for f in LocationRecorder.shared.lastSeen.values {
            MovementMonitor.shared.add(CLLocation(coordinate: f.coordinate, altitude: 0,
                                                  horizontalAccuracy: f.accuracy, verticalAccuracy: -1, timestamp: f.date))
        }
        await refresh(polls: foreground ? 3 : 2)
        evaluate(me: fix)
    }

    private func evaluate(me: CLLocation) {
        let myAcc = max(me.horizontalAccuracy, 0)
        for d in devices {
            let w = setting(d.id)
            guard w.enabled else { continue }
            guard let coord = d.coordinate, let at = d.locAt else {
                FindMyLog.log("\(d.name): no location from iCloud (\(d.online ? "online" : "offline"))")
                continue
            }
            let there = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            let dist = me.distance(from: there)
            let age = Date().timeIntervalSince(at)

            observe(d, coord: coord, at: at, dist: dist, age: age)

            let gap = max(0, dist - d.accuracy - myAcc)
            let line = "\(d.name): \(Int(dist)) m away, gap \(Int(gap)) m, location \(Int(age / 60)) min old"

            if dist <= max(80, d.accuracy + myAcc) {
                if alerted[d.id] != nil { alerted[d.id] = nil; save(alerted, "fmAlerted") }
                FindMyLog.log(line + ", with me")
                continue
            }
            // An old fix only says where it was hours ago, not where it is now. Offline devices
            // (dead battery, airplane mode) keep their last fix forever, so only fresh ones count.
            guard age < 20 * 60 else { FindMyLog.log(line + ", fix too old to judge (\(d.online ? "online" : "offline"))"); continue }
            guard gap > w.threshold else { FindMyLog.log(line + ", under \(Int(w.threshold)) m"); continue }
            if !w.always {
                guard let c = carried[d.id], Date().timeIntervalSince(c) < 24 * 3600 else {
                    FindMyLog.log(line + ", but it hasn't travelled with me lately, not alerting")
                    continue
                }
            }
            if alerted[d.id] != nil { FindMyLog.log(line + ", already alerted"); continue }
            if let p = TrustedPlaces.shared.places.first(where: { $0.mode == .ignore && contains($0, coord) }) {
                FindMyLog.log(line + ", inside ignored place \(p.name)")
                continue
            }
            FindMyLog.log(line + ", ALERT")
            alerted[d.id] = Date()
            save(alerted, "fmAlerted")
            notify(d, coord: coord, dist: dist, age: age)
        }
    }

    private func contains(_ p: Place, _ c: CLLocationCoordinate2D) -> Bool {
        CLLocation(latitude: p.lat, longitude: p.lon).distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)) <= p.radius
    }

    /// Remembers where each device was, and notes when one moved while I was next to it.
    private func observe(_ d: FMDevice, coord: CLLocationCoordinate2D, at: Date, dist: Double, age: TimeInterval) {
        let t = at.timeIntervalSince1970
        defer {
            if lastObs[d.id].map({ t > $0.t }) ?? true {
                lastObs[d.id] = Obs(lat: coord.latitude, lon: coord.longitude, t: t)
                save(lastObs, "fmObs")
            }
        }
        guard let prev = lastObs[d.id], t > prev.t else { return }
        let moved = CLLocation(latitude: prev.lat, longitude: prev.lon)
            .distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
        guard moved > 200 else { return }
        let withMe = MovementMonitor.shared.wasNear(coord, at: at, radius: max(120, d.accuracy)) || (age < 600 && dist < 150)
        FindMyLog.log("\(d.name) moved \(Int(moved)) m, \(withMe ? "with me" : "not matched to my trail")")
        if withMe {
            carried[d.id] = at
            save(carried, "fmCarried")
        }
    }

    private func notify(_ d: FMDevice, coord: CLLocationCoordinate2D, dist: Double, age: TimeInterval) {
        let unit = DistanceUnit(rawValue: defaults.string(forKey: DistanceUnit.storageKey) ?? "") ?? .localeDefault
        let ago: String = age < 90 ? "just now" : age < 5400 ? "\(Int(age / 60)) min ago" : "\(Int(age / 3600)) h ago"
        let name = d.name
        let id = d.id
        let state = d.online ? "It's online" : "It's offline"
        CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: coord.latitude, longitude: coord.longitude)) { pms, _ in
            let pm = pms?.first
            let street = [pm?.subThoroughfare, pm?.thoroughfare].compactMap { $0 }.joined(separator: " ")
            let place = street.isEmpty ? (pm?.name ?? pm?.locality) : street
            let content = UNMutableNotificationContent()
            content.title = "\(name) may be left behind"
            content.body = "\(state), \(unit.format(dist)) from you\(place.map { ", at \($0)" } ?? ""). Location updated \(ago)."
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "fm-left-\(id)", content: content, trigger: nil))
        }
    }

    // MARK: Actions

    func playSound(_ id: String) async -> String {
        do {
            try await client.playSound(id)
            return "Sound sent. The device plays it when it's online."
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - Background refresh

enum FindMyBackground {
    static let id = "com.soumen.findmyble.refresh"

    /// Call once at launch, before the app finishes starting.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
            schedule()
            let work = Task { @MainActor in
                await FindMyStore.shared.check("background refresh", force: true)
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    /// iOS decides the real time; this only asks for "not sooner than 15 minutes".
    static func schedule() {
        let r = BGAppRefreshTaskRequest(identifier: id)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }
}
