import AppIntents
import Foundation
import WidgetKit

@available(iOS 18.0, *) struct BLEControlConfig: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Tracked item"
    @Parameter(title: "Item") var item: ItemEntity?
}
struct FindItemIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Nearby"
    static var openAppWhenRun = true
    @Parameter(title: "Item") var item: ItemEntity?
    init() {}
    init(_ item: ItemEntity?) { self.item = item }
    @MainActor func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        guard let id = item.flatMap({ UUID(uuidString: $0.id) }), BLEMonitor.shared.item(id) != nil else {
            throw NSError(domain: "FindMyBLE", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a tracked item for this control."])
        }
        FindMyBLERoute.shared.finding = id
        #endif
        return .result()
    }
}
@available(iOS 18.0, *) struct ItemAlertsIntent: SetValueIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Item Left-Behind Alerts"
    @Parameter(title: "Item") var item: ItemEntity?
    @Parameter(title: "Enabled") var value: Bool
    init() {}
    init(_ item: ItemEntity?) { self.item = item }
    @MainActor func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        guard let id = item.flatMap({ UUID(uuidString: $0.id) }), BLEMonitor.shared.item(id) != nil else {
            throw NSError(domain: "FindMyBLE", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a tracked item for this control."])
        }
        BLEMonitor.shared.update(id) { $0.alertsEnabled = value }
        WidgetBridge.shared.refreshControls()
        #endif
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
        return .result()
    }
}
