import Foundation
import CoreBluetooth
import UserNotifications
import Combine

/// Presence-based tracker. Instead of holding a connection (which cheap gadgets like the
/// LARQ cap drop to save battery, then come back under a new random address), it listens
/// for the item's advertisements by name. Every sighting pushes the "left behind" alert
/// further into the future. If the item goes quiet for longer than the away timeout,
/// the alert fires, even with the app suspended, because the notification system owns the timer.
final class BLEMonitor: NSObject, ObservableObject {
    static let shared = BLEMonitor()

    static let restoreID = "com.soumen.findmyble.central"
    private let savedNameKey = "watchedPeripheralName"
    private let savedServicesKey = "watchedServiceUUIDs"
    private let matchKey = "matchPrefix"
    private let timeoutKey = "awayTimeout"
    private let alertsKey = "alertsEnabled"
    private let lastSeenKey = "lastSightingDate"
    private let holdKey = "holdConnection"
    private let powerSaveOffKey = "disablePowerSaving"
    private let lostAlertID = "ble-lost-alert"

    enum LinkStatus: String {
        case idle = "Not watching"
        case connecting = "Searching..."
        case connected = "With You"
        case lost = "LOST"
    }

    struct Device: Identifiable {
        let id: UUID
        let name: String
        var rssi: Int
        var services: [CBUUID]
    }

    @Published var btState: CBManagerState = .unknown
    @Published var devices: [Device] = []
    @Published var isScanning = false
    @Published var status: LinkStatus = .idle
    @Published var watchedName: String?
    @Published var rssi: Int?
    /// When the item was last heard from, i.e. when it went missing once status is .lost.
    @Published var lastLost: Date?
    @Published var lastSighting: Date?
    /// False when the item advertises no service UUID. iOS only lets apps scan for those
    /// in the background, so such an item is tracked only while the app is open.
    @Published var backgroundCapable = true

    /// Any advertised name starting with this counts as the item. Devices like the LARQ cap
    /// rotate the random part of their name ("LARQ_xxxx"), so exact matching would lose it.
    @Published var matchPrefix: String {
        didSet { UserDefaults.standard.set(matchPrefix, forKey: matchKey) }
    }

    /// Seconds without a sighting before it counts as left behind.
    @Published var graceSeconds: Double {
        didSet {
            UserDefaults.standard.set(graceSeconds, forKey: timeoutKey)
            if lastSighting != nil { rescheduleLostAlert() }
        }
    }

    @Published var alertsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(alertsEnabled, forKey: alertsKey)
            alertsEnabled ? rescheduleLostAlert() : cancelLostAlert()
        }
    }

    /// Hold an open connection to the item instead of only listening for advertisements.
    /// A connected peripheral usually keeps its radio awake, which stops the LARQ cap from
    /// dropping off. Presence tracking keeps running underneath, so left-behind still works.
    @Published var holdConnection: Bool {
        didSet {
            UserDefaults.standard.set(holdConnection, forKey: holdKey)
            if holdConnection { updateScan(force: true) } else { dropConnection() }
        }
    }

    /// When connected, tell the cap to turn its power-saving mode off (LARQ only, harmless).
    @Published var disablePowerSaving: Bool {
        didSet {
            UserDefaults.standard.set(disablePowerSaving, forKey: powerSaveOffKey)
            if disablePowerSaving, connected?.state == .connected { sendPowerSavingOff() }
        }
    }

    /// Battery level read over the standard service while connected. Nil when not connected.
    @Published var battery: Int?
    @Published var isConnected = false

    private var central: CBCentralManager!
    private var watchedServices: [CBUUID] = []
    private var lastScanRestart = Date.distantPast
    private var tick: Timer?

    /// The peripheral we currently hold or are connecting to. Retained so iOS keeps the link.
    private var connected: CBPeripheral?
    private var uartWriteChar: CBCharacteristic?

    private override init() {
        let t = UserDefaults.standard.double(forKey: timeoutKey)
        graceSeconds = t == 0 ? 180 : t
        alertsEnabled = UserDefaults.standard.object(forKey: alertsKey) as? Bool ?? true
        holdConnection = UserDefaults.standard.object(forKey: holdKey) as? Bool ?? false
        disablePowerSaving = UserDefaults.standard.object(forKey: powerSaveOffKey) as? Bool ?? false
        watchedName = UserDefaults.standard.string(forKey: savedNameKey)
        matchPrefix = UserDefaults.standard.string(forKey: matchKey)
            ?? UserDefaults.standard.string(forKey: savedNameKey).map { BLEMonitor.defaultPrefix(for: $0) } ?? ""
        watchedServices = (UserDefaults.standard.stringArray(forKey: savedServicesKey) ?? []).map(CBUUID.init(string:))
        lastSighting = UserDefaults.standard.object(forKey: lastSeenKey) as? Date
        super.init()

        backgroundCapable = watchedServices.isEmpty == false
        status = watchedName == nil ? .idle : .connecting

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID,
                      CBCentralManagerOptionShowPowerAlertKey: true]
        )

        // Foreground-only clock so the UI flips to "Left Behind" on time.
        tick = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    // MARK: - Public

    /// Scan for the Add Item list.
    func startScan() {
        devices.removeAll()
        isScanning = true
        updateScan(force: true)
    }

    func stopScan() {
        isScanning = false
        updateScan(force: true)
    }

    func watch(_ device: Device) {
        isScanning = false
        watchedName = device.name
        matchPrefix = Self.defaultPrefix(for: device.name)
        watchedServices = device.services
        backgroundCapable = !device.services.isEmpty
        UserDefaults.standard.set(device.name, forKey: savedNameKey)
        UserDefaults.standard.set(device.services.map(\.uuidString), forKey: savedServicesKey)
        lastLost = nil
        sighted(rssi: device.rssi, notifyBack: false)
        updateScan(force: true)
    }

    func unwatch() {
        watchedName = nil
        watchedServices = []
        UserDefaults.standard.removeObject(forKey: savedNameKey)
        UserDefaults.standard.removeObject(forKey: savedServicesKey)
        UserDefaults.standard.removeObject(forKey: lastSeenKey)
        lastSighting = nil
        lastLost = nil
        status = .idle
        rssi = nil
        dropConnection()
        cancelLostAlert()
        updateScan(force: true)
    }

    // MARK: - Connection hold (optional)

    private func connectIfNeeded(_ p: CBPeripheral) {
        guard holdConnection else { return }
        guard connected?.identifier != p.identifier || p.state == .disconnected else { return }
        connected = p
        p.delegate = self
        central.connect(p, options: nil)
    }

    private func dropConnection() {
        battery = nil
        isConnected = false
        uartWriteChar = nil
        if let p = connected { central.cancelPeripheralConnection(p) }
        connected = nil
    }

    private func sendPowerSavingOff() {
        guard disablePowerSaving, let p = connected, let ch = uartWriteChar else { return }
        let type: CBCharacteristicWriteType =
            ch.properties.contains(.write) ? .withResponse : .withoutResponse
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

    private func matches(_ name: String) -> Bool {
        let p = matchPrefix.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return false }
        return name.range(of: p, options: [.caseInsensitive, .anchored]) != nil
    }

    // MARK: - Scanning

    private func updateScan(force: Bool = false) {
        guard central.state == .poweredOn else { return }
        let wantWatch = watchedName != nil
        guard isScanning || wantWatch else { central.stopScan(); return }
        guard force || Date().timeIntervalSince(lastScanRestart) > 20 else { return }

        // Add-item scanning happens on screen, so no filter. Watching uses the item's
        // service UUIDs when it has them, which is what makes background scanning work.
        let services: [CBUUID]? = isScanning || watchedServices.isEmpty ? nil : watchedServices
        central.stopScan()
        central.scanForPeripherals(withServices: services,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        lastScanRestart = Date()
    }

    /// The item was heard from.
    private func sighted(rssi r: Int, notifyBack: Bool = true) {
        let now = Date()
        let wasAway = lastSighting.map { now.timeIntervalSince($0) > graceSeconds } ?? false

        if notifyBack, wasAway, alertsEnabled {
            let c = UNMutableNotificationContent()
            c.title = "\(watchedName ?? "Item") is back with you"
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }

        lastSighting = now
        UserDefaults.standard.set(now, forKey: lastSeenKey)
        rssi = r
        status = .connected
        lastLost = nil

        // "Where you left it" is wherever the phone was at the last sighting.
        if let fix = LocationRecorder.shared.lastSeen?.date, now.timeIntervalSince(fix) < 90 {
            // fresh enough
        } else {
            LocationRecorder.shared.recordNow()
        }

        rescheduleLostAlert()
        // In the background iOS reports each device once per scan; restarting the scan
        // now and then resets that, so sightings keep coming while it's in range.
        updateScan()
    }

    private func refreshStatus() {
        guard watchedName != nil else { return }
        guard let seen = lastSighting else { status = .connecting; return }
        if Date().timeIntervalSince(seen) > graceSeconds {
            if status != .lost { status = .lost; lastLost = seen; rssi = nil }
        }
    }

    // MARK: - Alerts

    private func rescheduleLostAlert() {
        cancelLostAlert()
        guard alertsEnabled, watchedName != nil else { return }
        let c = UNMutableNotificationContent()
        c.title = "\(watchedName ?? "Item") left behind"
        c.body = "Not heard from in \(Int(graceSeconds / 60)) min. Tap to see where it was last seen."
        c.sound = .defaultCritical
        c.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(graceSeconds, 30), repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: lostAlertID, content: c, trigger: trigger))
    }

    private func cancelLostAlert() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [lostAlertID])
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEMonitor: CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // Relaunched in the background; reclaim any connection we were holding.
        if let ps = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let p = ps.first {
            connected = p
            p.delegate = self
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        btState = central.state
        if central.state == .poweredOn { updateScan(force: true) }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard p.identifier == connected?.identifier else { return }
        isConnected = true
        p.discoverServices(Larq.allServices)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p.identifier == connected?.identifier else { return }
        isConnected = false
        battery = nil
        uartWriteChar = nil
        // Keep the link if the user still wants it; iOS reconnects when the cap is back.
        if holdConnection { central.connect(p, options: nil) } else { connected = nil }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p.identifier == connected?.identifier, holdConnection else { return }
        central.connect(p, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi RSSI: NSNumber) {
        let r = RSSI.intValue
        guard r != 127 else { return }
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name
        let services = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []

        if watchedName != nil, let name, matches(name) {
            sighted(rssi: r)
            connectIfNeeded(p)
        }

        guard isScanning, let name else { return }
        // Group by name, not peripheral ID: an address-rotating device would
        // otherwise show up as a new row every few minutes.
        if let i = devices.firstIndex(where: { $0.name == name }) {
            devices[i].rssi = r
            for s in services where !devices[i].services.contains(s) { devices[i].services.append(s) }
        } else {
            devices.append(Device(id: p.identifier, name: name, rssi: r, services: services))
        }
        devices.sort { $0.rssi > $1.rssi }
    }
}

// MARK: - CBPeripheralDelegate (connection-hold extras)

extension BLEMonitor: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] {
            p.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            switch c.uuid {
            case Larq.batteryLevel:
                p.setNotifyValue(true, for: c)
                p.readValue(for: c)
            case Larq.uartNotify:
                p.setNotifyValue(true, for: c)
            case Larq.uartWrite:
                uartWriteChar = c
                sendPowerSavingOff()
            default:
                break
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard error == nil, let data = c.value else { return }
        if c.uuid == Larq.batteryLevel, let b = data.first {
            battery = Int(b)
        }
        // UART notifications (c.uuid == Larq.uartNotify) are command responses; we don't
        // parse them here, the power-saving write is fire-and-forget.
    }
}

// MARK: - Show banners even when the app is open

extension BLEMonitor: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        refreshStatus()
        done([.banner, .sound, .list])
    }
}
