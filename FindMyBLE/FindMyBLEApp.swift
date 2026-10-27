import SwiftUI
import AppIntents

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


/// Pick a tracked item once in Shortcuts, then pin that shortcut to Control Center.
struct FindMyBLEShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: FindItemIntent(), phrases: [
            "Find my device using \(.applicationName)",
        ], shortTitle: "Find Nearby", systemImageName: "dot.radiowaves.left.and.right")
    }
}
