import Foundation
import CoreBluetooth
import UserNotifications
import UIKit
import SwiftUI

/// Presence-based tracker for any number of items. Instead of holding a connection (which cheap
/// gadgets like the LARQ cap drop to save battery, then come back under a new random address),
/// it listens for each item's advertisements by name prefix. Each sighting pushes that item's
/// "left behind" alert into the future, or re-centres its geofence in leave-area mode.
final class BLEMonitor: NSObject, ObservableObject {
    static let shared = BLEMonitor()
    static let restoreID = "com.soumen.findmyble.central"

    private let itemsKey = "trackedItems.v2"
    private let sightingsKey = "lastSightings.v2"
    private let heldKey = "heldPeripherals.v2"
    private let knownKey = "knownPeripherals.v2"
    private let batteryKey = "lastBattery.v2"
    private let legacyAlertID = "ble-lost-alert"

    struct Device: Identifiable {
        let id: UUID
        let name: String
        var rssi: Int
        var services: [CBUUID]
        /// Already connected to this phone (by us or another app), so it isn't advertising.
        var connected = false
    }

    @Published var btState: CBManagerState = .unknown
    @Published var devices: [Device] = []
    @Published var isScanning = false
    @Published private(set) var items: [TrackedItem] = []
    @Published private(set) var live: [UUID: ItemLive] = [:]
    /// Last battery reading per item, kept after the link drops so the list and widget still show it.
    @Published private(set) var lastBattery: [UUID: BatteryReading] = [:]

    private var central: CBCentralManager!
    private var lastScanRestart = Date.distantPast
    private var tick: Timer?
    private var connectedPoll: Timer?
    private var appActive = true

    /// Peripheral each item holds (or is connecting to). Retained so iOS keeps the link.
    private var held: [UUID: CBPeripheral] = [:]
    /// Last peripheral that matched each item, so the finder can connect on demand.
    private var lastPeripheral: [UUID: CBPeripheral] = [:]
    /// The peripheral identifier each item last matched, persisted. Lets us ask iOS for a pending
    /// connection at launch: iOS then reconnects on its own when the item is in range and wakes
    /// the app, even while it is suspended. That is what keeps Keep Connected alive in the background.
    private var knownPeripheral: [UUID: UUID] = [:]
    private var uartWrite: [UUID: CBCharacteristic] = [:]
    /// Item whose Find Nearby screen is open: connect and poll signal fast, then let go.
    private var finding: UUID?
    private var rssiPoll: Timer?

    // Throttles, so a chatty advertiser doesn't hammer region monitoring and notifications.
    private var lastAreaArm: [UUID: Date] = [:]
    private var lastTimerArm: [UUID: Date] = [:]
    private var lastPersist = Date.distantPast
    private var pendingResize: [UUID: DispatchWorkItem] = [:]

    /// After leaving an area, how long the item may stay unheard before alerting. Gives a cap
    /// that wakes on movement a chance to show itself so we don't alert on something in your bag.
    private let verifySeconds: TimeInterval = 30
    /// Items with a left-behind check in flight: the alert is queued, and any sign of the item
    /// (a live link, an advertisement) before it fires cancels it.
    private var verifying: [UUID: String] = [:]
    private var verifyTask: UIBackgroundTaskIdentifier = .invalid

    private override init() {
        super.init()
        loadItems()
        loadDeviceMemory()

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [legacyAlertID])

        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID,
                      CBCentralManagerOptionShowPowerAlertKey: true]
        )

        // Foreground-only clock so the UI flips to "Left Behind" on time.
        tick = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshAll()
        }

        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.appActive = true
            self?.updateScan(force: true)
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.appActive = false
            self?.persistSightings()
            self?.updateScan(force: true)
        }

        let loc = LocationRecorder.shared
        loc.onLeftArea = { [weak self] id in self?.handleLeftArea(id) }
        loc.onLeftPlace = { [weak self] p in self?.handleLeftPlace(p) }
        loc.pruneGeofences(keeping: Set(items.map(\.id)))
        for it in items where it.alertOnLeaveArea && loc.area[it.id] == nil {
            loc.armGeofence(for: it.id, radius: it.areaRadius)
        }
        loc.syncPlaceRegions(TrustedPlaces.shared.places)
    }

    // MARK: - Items

    func item(_ id: UUID) -> TrackedItem? { items.first { $0.id == id } }
    func state(_ id: UUID) -> ItemLive { live[id] ?? ItemLive() }

    /// Change an item's settings and apply whatever that change needs (geofence, alerts, link).
    func update(_ id: UUID, _ change: (inout TrackedItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let old = items[i]
        var new = old
        change(&new)
        new.areaRadius = min(max(new.areaRadius, TrackedItem.radiusRange.lowerBound), TrackedItem.radiusRange.upperBound)
        guard new != old else { return }
        items[i] = new
        saveItems()

        if !new.alertsEnabled { cancelLostAlert(id) }
        if new.alertOnLeaveArea != old.alertOnLeaveArea {
            cancelLostAlert(id)
            if new.alertOnLeaveArea {
                LocationRecorder.shared.armGeofence(for: id, radius: new.areaRadius)
            } else {
                LocationRecorder.shared.disarmGeofence(for: id)
                if state(id).lastSighting != nil { rescheduleLostAlert(id, force: true) }
            }
        }
        if new.areaRadius != old.areaRadius, new.alertOnLeaveArea {
            // The slider fires continuously; resize the real region once it settles.
            pendingResize[id]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let it = self.item(id) else { return }
                LocationRecorder.shared.resizeGeofence(for: id, radius: it.areaRadius)
            }
            pendingResize[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
        if new.graceSeconds != old.graceSeconds, !new.alertOnLeaveArea, state(id).lastSighting != nil {
            rescheduleLostAlert(id, force: true)
        }
        if new.holdConnection != old.holdConnection {
            if new.holdConnection {
                if let p = lastPeripheral[id] { connectIfNeeded(id, p) } else { reconnectKnown() }
                updateScan(force: true)
            } else if finding != id {
                dropConnection(id)
            }
        }
        if new.disablePowerSaving, !old.disablePowerSaving, held[id]?.state == .connected {
            sendPowerSavingOff(id)
        }
        if new.matchPrefix != old.matchPrefix || new.services != old.services { updateScan(force: true) }
    }

    func binding<T>(_ id: UUID, _ kp: WritableKeyPath<TrackedItem, T>, default d: T) -> Binding<T> {
        Binding(get: { [weak self] in self?.item(id)?[keyPath: kp] ?? d },
                set: { [weak self] v in self?.update(id) { $0[keyPath: kp] = v } })
    }

    /// Track a device from the Add Item list. Returns the new item's id.
    @discardableResult
    func add(_ d: Device) -> UUID {
        let used = Set(items.map(\.colorIndex))
        let color = (0..<ItemPalette.colors.count).first { !used.contains($0) } ?? items.count
        let it = TrackedItem(bluetoothName: d.name,
                             matchPrefix: Self.defaultPrefix(for: d.name),
                             services: d.services.map(\.uuidString),
                             colorIndex: color)
        items.append(it)
        live[it.id] = ItemLive()
        saveItems()
        if !d.connected { sighted(it.id, rssi: d.rssi, notifyBack: false) }
        else { live[it.id]?.lastSighting = Date(); LocationRecorder.shared.recordNow(for: it.id) }
        if it.alertOnLeaveArea { LocationRecorder.shared.armGeofence(for: it.id, radius: it.areaRadius) }
        updateScan(force: true)
        return it.id
    }

    func remove(_ id: UUID) {
        dropConnection(id)
        cancelLostAlert(id)
        pendingResize[id]?.cancel()
        LocationRecorder.shared.forget(id)
        items.removeAll { $0.id == id }
        live[id] = nil
        lastPeripheral[id] = nil
        knownPeripheral[id] = nil
        lastBattery[id] = nil
        saveDeviceMemory()
        WidgetBridge.shared.forget(id)
        lastAreaArm[id] = nil
        lastTimerArm[id] = nil
        saveItems()
        persistSightings()
        updateScan(force: true)
    }

    // MARK: - Add Item scan

    func startScan() {
        devices.removeAll()
        isScanning = true
        updateScan(force: true)
        pollConnected()
        connectedPoll?.invalidate()
        connectedPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.pollConnected()
        }
    }

    func stopScan() {
        isScanning = false
        connectedPoll?.invalidate()
        connectedPoll = nil
        updateScan(force: true)
        reconnectKnown()   // Add Item held off on connecting; pick the links back up
    }

    /// A connected peripheral stops advertising, so a scan alone never shows it. This is why a
    /// LARQ cap held open (by Keep Connected, Find Nearby, or the LARQ app) vanished from Add Item.
    /// Ask iOS for anything already connected that speaks the LARQ or a tracked item's services.
    private func pollConnected() {
        guard isScanning, central.state == .poweredOn else { return }
        let svc = Array(Set(Larq.allServices + items.flatMap(\.serviceUUIDs)))
        for p in central.retrieveConnectedPeripherals(withServices: svc) {
            guard let name = p.name, !name.isEmpty else { continue }
            if let i = devices.firstIndex(where: { $0.name == name }) {
                devices[i].connected = true
            } else {
                devices.append(Device(id: p.identifier, name: name, rssi: -127,
                                      services: [], connected: true))
            }
        }
    }

    // MARK: - Finder

    /// Find Nearby opened: grab a live connection (even if Keep Connected is off) and poll signal
    /// fast, because connection RSSI updates steadily while advertisements barely trickle in.
    func beginFinding(_ id: UUID) {
        finding = id
        if let p = held[id] ?? lastPeripheral[id] {
            bind(id, p)
            if p.state != .connected { central.connect(p, options: nil) }
            startRssiPoll()
        }
    }

    func endFinding(_ id: UUID) {
        guard finding == id else { return }
        finding = nil
        stopRssiPoll()
        if item(id)?.holdConnection != true { dropConnection(id) }
    }

    private func startRssiPoll() {
        stopRssiPoll()
        rssiPoll = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            guard let self, let id = self.finding, let p = self.held[id], p.state == .connected else { return }
            p.readRSSI()
        }
    }

    private func stopRssiPoll() {
        rssiPoll?.invalidate()
        rssiPoll = nil
    }

    // MARK: - Connections

    private func bind(_ id: UUID, _ p: CBPeripheral) {
        held[id] = p
        p.delegate = self
        saveHeld()
        remember(id, p)
    }

    private func remember(_ id: UUID, _ p: CBPeripheral) {
        guard knownPeripheral[id] != p.identifier else { return }
        knownPeripheral[id] = p.identifier
        saveDeviceMemory()
    }

    /// For every Keep Connected item without a live link: reclaim one iOS already has open (this
    /// app's or the LARQ app's), else queue a pending connect to its last-known peripheral.
    /// Pending connects never time out, so this keeps working while the app is suspended.
    /// If the device has since changed address, advertisements pick it up instead.
    private func reconnectKnown() {
        guard central.state == .poweredOn, !isScanning else { return }
        let want = items.filter { $0.holdConnection && (held[$0.id] == nil || held[$0.id]?.state == .disconnected) }
        guard !want.isEmpty else { return }
        let svc = Array(Set(Larq.allServices + want.flatMap(\.serviceUUIDs)))
        let open = central.retrieveConnectedPeripherals(withServices: svc)
        for it in want {
            if let p = open.first(where: { p in
                p.identifier == knownPeripheral[it.id] || (p.name.map(it.matches) ?? false)
            }) {
                lastPeripheral[it.id] = p
                connectIfNeeded(it.id, p)
            } else if let pid = knownPeripheral[it.id],
                      let p = central.retrievePeripherals(withIdentifiers: [pid]).first {
                lastPeripheral[it.id] = p
                connectIfNeeded(it.id, p)
            }
        }
    }

    private func connectIfNeeded(_ id: UUID, _ p: CBPeripheral) {
        guard item(id)?.holdConnection == true else { return }
        // While Add Item is open, don't grab a new link: a connected cap stops advertising.
        guard !isScanning else { return }
        if let h = held[id], h.identifier == p.identifier, h.state != .disconnected { return }
        // Already held for a different item (two items matching one device): leave it.
        if held.contains(where: { $0.key != id && $0.value.identifier == p.identifier }) { return }
        bind(id, p)
        central.connect(p, options: nil)
    }

    private func dropConnection(_ id: UUID) {
        live[id]?.battery = nil
        live[id]?.isConnected = false
        uartWrite[id] = nil
        if finding == id { stopRssiPoll() }
        if let p = held[id] { central.cancelPeripheralConnection(p) }
        held[id] = nil
        saveHeld()
    }

    private func itemID(for p: CBPeripheral) -> UUID? {
        held.first { $0.value.identifier == p.identifier }?.key
    }

    private func sendPowerSavingOff(_ id: UUID) {
        guard item(id)?.disablePowerSaving == true, let p = held[id], let ch = uartWrite[id] else { return }
        let type: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(Larq.powerSavingOff(), for: ch, type: type)
    }

    // MARK: - Name matching

    /// "LARQ_AddzOy6Y39n" -> "LARQ_". Names with no separator are matched whole.
    static func defaultPrefix(for name: String) -> String {
        if let i = name.firstIndex(where: { $0 == "_" || $0 == "-" || $0 == " " }) {
            return String(name[...i])
        }
        return name
    }

    /// Items an advertisement belongs to. If this exact peripheral is already tied to one of the
    /// matching items, it's that one; otherwise every item whose prefix matches counts it.
    private func owners(of name: String, _ p: CBPeripheral) -> [UUID] {
        let c = items.filter { $0.matches(name) }
        if c.count > 1,
           let bound = c.first(where: { held[$0.id]?.identifier == p.identifier
                                        || lastPeripheral[$0.id]?.identifier == p.identifier }) {
            return [bound.id]
        }
        return c.map(\.id)
    }

    // MARK: - Scanning

    private func updateScan(force: Bool = false) {
        guard central.state == .poweredOn else { return }
        guard isScanning || !items.isEmpty else { central.stopScan(); return }
        guard force || Date().timeIntervalSince(lastScanRestart) > 20 else { return }

        // Add Item, or an item that advertises no service, needs an open scan (foreground only).
        // Otherwise scan for the items' service UUIDs, which is what works in the background.
        let union = Array(Set(items.flatMap(\.serviceUUIDs)))
        let open = isScanning || union.isEmpty || (appActive && items.contains { !$0.backgroundCapable })
        central.stopScan()
        central.scanForPeripherals(withServices: open ? nil : union,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        lastScanRestart = Date()
    }

    /// An item was heard from.
    private func sighted(_ id: UUID, rssi r: Int, notifyBack: Bool = true) {
        guard let it = item(id) else { return }
        let now = Date()
        var s = state(id)
        let wasAway = s.lastSighting.map { now.timeIntervalSince($0) > it.graceSeconds } ?? false

        if notifyBack, wasAway, it.alertsEnabled, it.notifyReturns {
            let c = UNMutableNotificationContent()
            c.title = "\(it.title) is back with you"
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }

        foundDuringCheck(id)
        s.lastSighting = now
        s.rssi = r
        s.rssiAt = now
        s.status = .connected
        s.lastLost = nil
        if live[id] != s { live[id] = s }
        if now.timeIntervalSince(lastPersist) > 15 { persistSightings() }

        // "Where you left it" is wherever the phone was at the last sighting.
        let loc = LocationRecorder.shared
        if let fix = loc.lastSeen[id]?.date, now.timeIntervalSince(fix) < 90 {
            // fresh enough
        } else {
            loc.recordNow(for: id)
        }

        if it.alertOnLeaveArea {
            // Heard from it, so no alert is pending. Re-centre its ring on where we are now so
            // "the area it's in" follows it while it's with us (at most once a minute).
            cancelLostAlert(id)
            if loc.area[id] == nil || now.timeIntervalSince(lastAreaArm[id] ?? .distantPast) > 60 {
                lastAreaArm[id] = now
                loc.armGeofence(for: id, radius: it.areaRadius)
            }
        } else if s.isConnected {
            cancelLostAlert(id)
        } else {
            rescheduleLostAlert(id)
        }
        // In the background iOS reports each device once per scan; restarting now and then
        // resets that, so sightings keep coming while it's in range.
        updateScan()
    }

    private func refreshAll() {
        for it in items { refreshStatus(it) }
    }

    private func refreshStatus(_ it: TrackedItem) {
        var s = state(it.id)
        defer { if live[it.id] != s { live[it.id] = s } }
        // An open connection means it's with us.
        if s.isConnected {
            if s.status != .connected { s.status = .connected; s.lastLost = nil }
            return
        }
        guard let seen = s.lastSighting else { s.status = .connecting; return }
        let silent = Date().timeIntervalSince(seen) > it.graceSeconds
        // In area mode a long silence usually just means the cap is napping nearby, so don't
        // show LOST on a timer; the notification fires only when you actually leave the area.
        if it.alertOnLeaveArea {
            if silent, s.status == .connected { s.status = .connecting; s.rssi = nil }
        } else if silent, s.status != .lost {
            s.status = .lost; s.lastLost = seen; s.rssi = nil
        }
    }

    // MARK: - Leaving

    /// Left a trusted place set to "remind": nudge for every item that didn't come with you.
    private func handleLeftPlace(_ p: Place) {
        guard p.mode == .remind else { return }
        for it in items where it.alertsEnabled {
            // 90 s grace: a cap that isn't held connected naps between adverts while sitting in your bag.
            confirmLeftBehind(it.id, heardWithin: 90, body: "You left \(p.name) without \(it.title). Grab it?")
        }
    }

    /// Is the item with the phone right now? Asks iOS directly instead of trusting our own
    /// bookkeeping, which starts empty when iOS relaunches the app for a geofence exit, and goes
    /// stale while a connected cap stops advertising.
    func isPresent(_ id: UUID, heardWithin recent: TimeInterval = 20) -> Bool {
        guard let it = item(id) else { return false }
        let s = state(id)
        if s.isConnected || held[id]?.state == .connected { return true }
        if let t = s.lastSighting, Date().timeIntervalSince(t) < recent { return true }
        guard central.state == .poweredOn else { return false }
        // Connected at the system level, by this app or another (the LARQ app), means in range.
        let svc = Array(Set(Larq.allServices + it.serviceUUIDs))
        return central.retrieveConnectedPeripherals(withServices: svc).contains { p in
            p.identifier == knownPeripheral[id] || (p.name.map(it.matches) ?? false)
        }
    }

    /// The phone just left somewhere. Queue the alert first (so it still fires if iOS suspends us),
    /// then actually look for the item and cancel the alert the moment it turns up.
    private func confirmLeftBehind(_ id: UUID, heardWithin recent: TimeInterval = 20, body: String) {
        if isPresent(id, heardWithin: recent) { adoptSystemLink(id); return }
        scheduleLostAlert(id, after: verifySeconds, body: body)
        verifying[id] = body
        if verifyTask == .invalid {
            verifyTask = UIApplication.shared.beginBackgroundTask(withName: "leftBehindCheck") { [weak self] in
                self?.endVerifyTask()
            }
        }
        // Bluetooth may not be up yet in a fresh background launch; poweredOn re-runs this.
        reconnectKnown()
        updateScan(force: true)
        for delay in [2.0, 6.0, 12.0, 20.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.recheckVerifying() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in self?.endVerifyTask() }
    }

    private func recheckVerifying() {
        for id in Array(verifying.keys) where isPresent(id) { foundDuringCheck(id) }
    }

    /// It turned up: drop the queued alert.
    private func foundDuringCheck(_ id: UUID) {
        guard verifying.removeValue(forKey: id) != nil else { return }
        cancelLostAlert(id)
        adoptSystemLink(id)
        if verifying.isEmpty { endVerifyTask() }
    }

    private func endVerifyTask() {
        if verifyTask != .invalid { UIApplication.shared.endBackgroundTask(verifyTask) }
        verifyTask = .invalid
    }

    /// If iOS has the item connected but our state says otherwise, take the link over and mark it.
    private func adoptSystemLink(_ id: UUID) {
        guard central.state == .poweredOn, let it = item(id), !state(id).isConnected else { return }
        let svc = Array(Set(Larq.allServices + it.serviceUUIDs))
        if let p = held[id].flatMap({ $0.state == .connected ? $0 : nil })
            ?? central.retrieveConnectedPeripherals(withServices: svc).first(where: { p in
                p.identifier == knownPeripheral[id] || (p.name.map(it.matches) ?? false) }) {
            bind(id, p)
            if p.state == .connected { markConnected(id, p) } else { central.connect(p, options: nil) }
        }
    }

    /// Bring our state in line with a link that's already up (restored after a relaunch, or opened
    /// by another app). didConnect doesn't fire for these.
    private func markConnected(_ id: UUID, _ p: CBPeripheral) {
        var s = state(id)
        s.isConnected = true
        s.status = .connected
        s.lastLost = nil
        s.lastSighting = Date()
        live[id] = s
        p.delegate = self
        refreshServices(p)
    }

    /// Re-read battery and the UART on a link we didn't open ourselves. Needs Bluetooth up.
    private func refreshServices(_ p: CBPeripheral) {
        guard central?.state == .poweredOn, p.state == .connected else { return }
        if let svcs = p.services, !svcs.isEmpty {
            for sv in svcs { p.discoverCharacteristics(nil, for: sv) }
        } else {
            p.discoverServices(Larq.allServices)
        }
    }

    /// The phone left the area where this item was last heard. If we don't clearly have it
    /// right now, arm a short verification: alert unless it shows up within the window.
    private func handleLeftArea(_ id: UUID) {
        guard let it = item(id), it.alertsEnabled, it.alertOnLeaveArea else { return }
        let loc = LocationRecorder.shared
        // Item sitting in a trusted place? The place's own logic owns it (and honours "ignore").
        if let c = loc.area[id]?.coordinate ?? loc.lastSeen[id]?.coordinate,
           TrustedPlaces.shared.containing(c) != nil {
            return
        }
        if isPresent(id) {
            // It's with us, the area just moved. Re-centre and don't alert.
            adoptSystemLink(id)
            loc.recordNow(for: id)
            lastAreaArm[id] = Date()
            loc.armGeofence(for: id, radius: it.areaRadius)
            return
        }
        confirmLeftBehind(id, body: "You seem to have left without it. Tap to see where it is.")
    }

    // MARK: - Alerts

    private func alertID(_ id: UUID) -> String { "ble-lost-\(id.uuidString)" }

    /// Time-based alert (only when "leave area" is off for this item).
    private func rescheduleLostAlert(_ id: UUID, force: Bool = false) {
        guard let it = item(id), !it.alertOnLeaveArea else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastTimerArm[id] ?? .distantPast) > 10 else { return }
        lastTimerArm[id] = now
        scheduleLostAlert(id, after: max(it.graceSeconds, 30),
                          body: "Not heard from in \(Int(it.graceSeconds / 60)) min. Tap to see where it was last seen.")
    }

    private func scheduleLostAlert(_ id: UUID, after: TimeInterval, body: String) {
        cancelLostAlert(id)
        guard let it = item(id), it.alertsEnabled else { return }
        let c = UNMutableNotificationContent()
        c.title = "\(it.title) left behind"
        c.body = body
        c.sound = .defaultCritical
        c.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(after, 1), repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: alertID(id), content: c, trigger: trigger))
    }

    private func cancelLostAlert(_ id: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [alertID(id)])
    }

    // MARK: - Persistence

    private func saveItems() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: itemsKey) }
    }

    private func persistSightings() {
        lastPersist = Date()
        var out: [String: Date] = [:]
        for (id, s) in live { if let t = s.lastSighting { out[id.uuidString] = t } }
        UserDefaults.standard.set(out, forKey: sightingsKey)
    }

    private func saveHeld() {
        UserDefaults.standard.set(held.reduce(into: [String: String]()) { $0[$1.key.uuidString] = $1.value.identifier.uuidString },
                                  forKey: heldKey)
    }

    private func saveDeviceMemory() {
        let ud = UserDefaults.standard
        ud.set(knownPeripheral.reduce(into: [String: String]()) { $0[$1.key.uuidString] = $1.value.uuidString }, forKey: knownKey)
        if let d = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: lastBattery.map { ($0.key.uuidString, $0.value) })) {
            ud.set(d, forKey: batteryKey)
        }
    }

    private func loadDeviceMemory() {
        let ud = UserDefaults.standard
        for (k, v) in ud.dictionary(forKey: knownKey) as? [String: String] ?? [:] {
            if let id = UUID(uuidString: k), let pid = UUID(uuidString: v) { knownPeripheral[id] = pid }
        }
        if let d = ud.data(forKey: batteryKey),
           let b = try? JSONDecoder().decode([String: BatteryReading].self, from: d) {
            for (k, v) in b { if let id = UUID(uuidString: k) { lastBattery[id] = v } }
        }
    }

    private func loadItems() {
        let ud = UserDefaults.standard
        if let d = ud.data(forKey: itemsKey), let saved = try? JSONDecoder().decode([TrackedItem].self, from: d) {
            items = saved
        } else {
            migrateSingleItem()
        }
        let seen = ud.dictionary(forKey: sightingsKey) as? [String: Date] ?? [:]
        for it in items {
            var s = ItemLive()
            s.lastSighting = seen[it.id.uuidString]
            live[it.id] = s
        }
    }

    /// Builds before multi-item kept one item in loose keys. Carry it over with its settings.
    private func migrateSingleItem() {
        let ud = UserDefaults.standard
        guard let name = ud.string(forKey: "watchedPeripheralName") else { return }
        var it = TrackedItem(bluetoothName: name,
                             matchPrefix: ud.string(forKey: "matchPrefix") ?? Self.defaultPrefix(for: name),
                             services: ud.stringArray(forKey: "watchedServiceUUIDs") ?? [],
                             colorIndex: 0)
        it.displayName = ud.string(forKey: "customDisplayName") ?? ""
        let t = ud.double(forKey: "awayTimeout"); if t > 0 { it.graceSeconds = t }
        let r = ud.double(forKey: "areaRadius"); if r > 0 { it.areaRadius = r }
        it.alertsEnabled = ud.object(forKey: "alertsEnabled") as? Bool ?? true
        it.alertOnLeaveArea = ud.object(forKey: "alertOnLeaveArea") as? Bool ?? true
        it.notifyReturns = ud.object(forKey: "notifyReturns") as? Bool ?? false
        it.holdConnection = ud.object(forKey: "holdConnection") as? Bool ?? false
        it.disablePowerSaving = ud.object(forKey: "disablePowerSaving") as? Bool ?? false
        items = [it]
        saveItems()
        if let last = ud.object(forKey: "lastSightingDate") as? Date {
            ud.set([it.id.uuidString: last], forKey: sightingsKey)
        }
        LocationRecorder.shared.adoptLegacyFix(for: it.id)
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEMonitor: CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // Relaunched in the background; reclaim the links we were holding, by item.
        guard let ps = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] else { return }
        let map = UserDefaults.standard.dictionary(forKey: heldKey) as? [String: String] ?? [:]
        for (itemStr, perStr) in map {
            guard let id = UUID(uuidString: itemStr), item(id) != nil,
                  let p = ps.first(where: { $0.identifier.uuidString == perStr }) else { continue }
            held[id] = p
            p.delegate = self
            if p.state == .connected { markConnected(id, p) }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        btState = central.state
        if central.state == .poweredOn {
            updateScan(force: true)
            // Links restored or opened by another app don't send didConnect; pick them up here.
            for it in items { adoptSystemLink(it.id) }
            for p in held.values where p.state == .connected { refreshServices(p) }
            reconnectKnown()
            recheckVerifying()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard let id = itemID(for: p), let it = item(id) else { return }
        var s = state(id)
        s.isConnected = true
        s.status = .connected
        s.lastLost = nil
        s.lastSighting = Date()
        live[id] = s
        persistSightings()
        cancelLostAlert(id)
        foundDuringCheck(id)
        LocationRecorder.shared.recordNow(for: id)
        if it.alertOnLeaveArea {
            lastAreaArm[id] = Date()
            LocationRecorder.shared.armGeofence(for: id, radius: it.areaRadius)
        }
        if finding == id { startRssiPoll() }
        p.readRSSI()
        p.discoverServices(Larq.allServices)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard let id = itemID(for: p), let it = item(id) else { return }
        var s = state(id)
        s.isConnected = false
        s.battery = nil
        // Just lost the link: count from now and record where we were, in case this is the
        // moment it got left behind. Advertisements resume feeding it if still in range.
        s.lastSighting = Date()
        live[id] = s
        persistSightings()
        uartWrite[id] = nil
        if finding == id { stopRssiPoll() }
        LocationRecorder.shared.recordNow(for: id)
        if it.alertOnLeaveArea {
            lastAreaArm[id] = Date()
            LocationRecorder.shared.armGeofence(for: id, radius: it.areaRadius)
        } else {
            rescheduleLostAlert(id, force: true)
        }
        if it.holdConnection || finding == id {
            central.connect(p, options: nil)
        } else {
            held[id] = nil
            saveHeld()
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard let id = itemID(for: p), item(id)?.holdConnection == true else { return }
        central.connect(p, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi RSSI: NSNumber) {
        let r = RSSI.intValue
        guard r != 127 else { return }
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name
        let services = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []

        if let name {
            for id in owners(of: name, p) {
                lastPeripheral[id] = p
                remember(id, p)
                sighted(id, rssi: r)
                connectIfNeeded(id, p)
                if finding == id, held[id] == nil { beginFinding(id) }
            }
        }

        guard isScanning, let name, !name.isEmpty else { return }
        // Group by name, not peripheral ID: an address-rotating device would otherwise show
        // up as a new row every few minutes.
        if let i = devices.firstIndex(where: { $0.name == name }) {
            devices[i].rssi = r
            devices[i].connected = false
            for s in services where !devices[i].services.contains(s) { devices[i].services.append(s) }
        } else {
            devices.append(Device(id: p.identifier, name: name, rssi: r, services: services))
        }
        devices.sort { ($0.connected ? 0 : $0.rssi) > ($1.connected ? 0 : $1.rssi) }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEMonitor: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let id = itemID(for: p) else { return }
        for c in s.characteristics ?? [] {
            switch c.uuid {
            case Larq.batteryLevel:
                p.setNotifyValue(true, for: c)
                p.readValue(for: c)
            case Larq.uartNotify:
                p.setNotifyValue(true, for: c)
            case Larq.uartWrite:
                uartWrite[id] = c
                sendPowerSavingOff(id)
            default:
                break
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil, RSSI.intValue != 127, let id = itemID(for: p) else { return }
        live[id]?.rssi = RSSI.intValue
        live[id]?.rssiAt = Date()
        live[id]?.lastSighting = Date()
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard error == nil, let data = c.value, let id = itemID(for: p) else { return }
        if c.uuid == Larq.batteryLevel, let b = data.first, b <= 100 {
            live[id]?.battery = Int(b)
            lastBattery[id] = BatteryReading(level: Int(b), at: .now)
            saveDeviceMemory()
        }
    }
}

// MARK: - Show banners even when the app is open

extension BLEMonitor: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        refreshAll()
        done([.banner, .sound, .list])
    }
}
