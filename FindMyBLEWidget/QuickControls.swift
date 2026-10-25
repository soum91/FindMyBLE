import SwiftUI
import WidgetKit
import AppIntents
@available(iOS 18.0, *) struct BLEAlertValue { var item: ItemEntity?; var enabled: Bool }
@available(iOS 18.0, *) struct BLEAlertProvider: AppIntentControlValueProvider {
    func previewValue(configuration: BLEControlConfig) -> BLEAlertValue { .init(item: configuration.item, enabled: true) }
    func currentValue(configuration: BLEControlConfig) async throws -> BLEAlertValue {
        guard let item = configuration.item, let snap = SharedSnapshot.load().items.first(where: { $0.id.uuidString == item.id }), let enabled = snap.alertsEnabled else {
            throw NSError(domain: "FindMyBLE", code: 1, userInfo: [NSLocalizedDescriptionKey: "Open FindMyBLE and choose an item for this control."])
        }
        return .init(item: item, enabled: enabled)
    }
}
@available(iOS 18.0, *) struct ItemAlertsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "com.soumen.findmyble.alerts", provider: BLEAlertProvider()) { value in
            ControlWidgetToggle(value.item?.title ?? "Left-behind alerts", isOn: value.enabled, action: ItemAlertsIntent(value.item)) { Label($0 ? "Alerts on" : "Alerts off", systemImage: $0 ? "bell.fill" : "bell.slash") }
        }.displayName("Item alerts").description("Enable or disable left-behind alerts for a chosen item.")
    }
}
@available(iOS 18.0, *) struct FindItemControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "com.soumen.findmyble.find", intent: BLEControlConfig.self) { config in
            ControlWidgetButton(action: FindItemIntent(config.item)) { Label(config.item?.title ?? "Choose an item", systemImage: "dot.radiowaves.left.and.right") }
        }.displayName("Find Nearby").description("Open the nearby signal finder for your chosen item.")
    }
}
