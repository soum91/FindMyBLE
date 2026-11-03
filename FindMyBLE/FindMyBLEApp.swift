import SwiftUI
import AppIntents
import UIKit

@main
struct FindMyBLEApp: App {
    init() {
        // Create the monitor at launch (not lazily in a view) so that when iOS relaunches
        // the app in the background for a BLE event, the central with the restore ID exists.
        _ = BLEMonitor.shared
        _ = LocationRecorder.shared
        WidgetBridge.shared.start()
        // Find My: register the background refresh before launch finishes, and listen for
        // visits and big moves so iOS can wake the app to check on your devices.
        FindMyBackground.register()
        Task { @MainActor in FindMyStore.shared.start() }
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
