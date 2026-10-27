import AppIntents
import WidgetKit

/// The widget's "+" button. Runs without opening the app.
struct LogWaterIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Log Water"
    static var description = IntentDescription("Adds one glass to today's water.")
    static var openAppWhenRun = false

    init() {}

    func perform() async throws -> some IntentResult {
        WaterLog.add()
        return .result()
    }
}
