import SwiftUI

@main
struct FindMyBLEApp: App {
    init() {
        // Create the monitor at launch (not lazily in a view) so that when iOS relaunches
        // the app in the background for a BLE event, the central with the restore ID exists.
        _ = BLEMonitor.shared
        _ = LocationRecorder.shared
        WidgetBridge.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
