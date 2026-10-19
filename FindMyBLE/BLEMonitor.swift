import Foundation
import CoreBluetooth
import UserNotifications
import Combine

/// Holds a connection to one BLE peripheral and alerts when it drops.
/// Works in the background via the bluetooth-central background mode + state restoration.
final class BLEMonitor: NSObject, ObservableObject {
    static let shared = BLEMonitor()

    static let restoreID = "com.soumen.findmyble.central"
    private let savedIDKey = "watchedPeripheralID"
    private let savedNameKey = "watchedPeripheralName"
    private let graceKey = "graceSeconds"
    private let lostAlertID = "ble-lost-alert"
    private let alertsKey = "alertsEnabled"

    enum LinkStatus: String {
        case idle = "Not watching"
        case connecting = "Connecting..."
        case connected = "Connected"
        case lost = "LOST"
    }

    struct Device: Identifiable {
        let id: UUID
        let name: String
        var rssi: Int
        let peripheral: CBPeripheral
    }

    @Published var btState: CBManagerState = .unknown
    @Published var devices: [Device] = []
    @Published var isScanning = false
    @Published var status: LinkStatus = .idle
    @Published var watchedName: String?
    @Published var rssi: Int?
    @Published var lastLost: Date?
    /// Seconds to wait before alerting. If it reconnects within this window, no alert fires.
    @Published var graceSeconds: Double {
        didSet { UserDefaults.standard.set(graceSeconds, forKey: graceKey) }
    }

    /// "Notify When Left Behind". Off = keep tracking, no notifications.
    @Published var alertsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(alertsEnabled, forKey: alertsKey)
            if !alertsEnabled { cancelLostAlert() }
        }
    }

    private var central: CBCentralManager!
    private var watched: CBPeripheral?
    private var rssiTimer: Timer?

    private override init() {
        let g = UserDefaults.standard.double(forKey: graceKey)
        graceSeconds = g == 0 ? 8 : g
        watchedName = UserDefaults.standard.string(forKey: savedNameKey)
        alertsEnabled = UserDefaults.standard.object(forKey: alertsKey) as? Bool ?? true
        super.init()

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID,
                      CBCentralManagerOptionShowPowerAlertKey: true]
        )
    }

    // MARK: - Public

    func startScan() {
        guard central.state == .poweredOn else { return }
        devices.removeAll()
        isScanning = true
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
    }

    func watch(_ device: Device) {
        stopScan()
        if let old = watched, old.identifier != device.id { central.cancelPeripheralConnection(old) }
        UserDefaults.standard.set(device.id.uuidString, forKey: savedIDKey)
        UserDefaults.standard.set(device.name, forKey: savedNameKey)
        watchedName = device.name
        attach(device.peripheral)
    }

    func unwatch() {
        if let p = watched { central.cancelPeripheralConnection(p) }
        watched = nil
        UserDefaults.standard.removeObject(forKey: savedIDKey)
        UserDefaults.standard.removeObject(forKey: savedNameKey)
        watchedName = nil
        status = .idle
        rssi = nil
        stopRSSI()
        cancelLostAlert()
    }

    // MARK: - Internals

    private func attach(_ p: CBPeripheral) {
        watched = p
        p.delegate = self
        status = .connecting
        // A pending connect never times out on iOS. If the device is out of range,
        // iOS keeps trying in the background and calls didConnect when it comes back.
        central.connect(p, options: nil)
    }

    private func reattachSaved() {
        guard watched == nil,
              let s = UserDefaults.standard.string(forKey: savedIDKey),
              let id = UUID(uuidString: s),
              let p = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        attach(p)
    }

    private func scheduleLostAlert() {
        guard alertsEnabled else { return }
        let c = UNMutableNotificationContent()
        c.title = "\(watchedName ?? "Device") disconnected"
        c.body = "You might have left it behind. Tap to see where it was last seen."
        c.sound = .defaultCritical
        c.interruptionLevel = .timeSensitive
        // Scheduled through the notification system so it fires even while the app is suspended.
        // Cancelled in didConnect if the link comes back inside the grace window.
        let trigger = graceSeconds >= 1
            ? UNTimeIntervalNotificationTrigger(timeInterval: graceSeconds, repeats: false)
            : nil
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: lostAlertID, content: c, trigger: trigger))
    }

    private func cancelLostAlert() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [lostAlertID])
    }

    private func startRSSI() {
        stopRSSI()
        rssiTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.watched?.readRSSI()
        }
    }

    private func stopRSSI() {
        rssiTimer?.invalidate()
        rssiTimer = nil
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEMonitor: CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // iOS relaunched us in the background. Grab the peripheral we were holding.
        if let ps = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let p = ps.first {
            watched = p
            p.delegate = self
            status = p.state == .connected ? .connected : .connecting
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        btState = central.state
        guard central.state == .poweredOn else { return }
        if let p = watched {
            if p.state != .connected { central.connect(p, options: nil) }
        } else {
            reattachSaved()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        guard let name, RSSI.intValue != 127 else { return }
        if let i = devices.firstIndex(where: { $0.id == p.identifier }) {
            devices[i].rssi = RSSI.intValue
        } else {
            devices.append(Device(id: p.identifier, name: name, rssi: RSSI.intValue, peripheral: p))
        }
        devices.sort { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        cancelLostAlert()
        if alertsEnabled, status == .lost, let lost = lastLost, Date().timeIntervalSince(lost) > graceSeconds {
            let c = UNMutableNotificationContent()
            c.title = "\(watchedName ?? "Device") is back in range"
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
        status = .connected
        startRSSI()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p.identifier == watched?.identifier else { return }
        stopRSSI()
        rssi = nil
        status = .lost
        lastLost = Date()
        LocationRecorder.shared.recordNow()
        scheduleLostAlert()
        central.connect(p, options: nil) // re-arm so we know when it's back
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p.identifier == watched?.identifier else { return }
        central.connect(p, options: nil)
    }
}

// MARK: - CBPeripheralDelegate

extension BLEMonitor: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if error == nil { rssi = RSSI.intValue }
    }
}

// MARK: - Show banners even when the app is open

extension BLEMonitor: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound, .list])
    }
}
