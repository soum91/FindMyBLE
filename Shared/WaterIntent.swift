import AppIntents
import WidgetKit

/// The widget's "+" button. Runs without opening the app.
struct LogWaterIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Water"
    static var description = IntentDescription("Adds one glass to today's water.")
    static var openAppWhenRun = false

    init() {}

    func perform() async throws -> some IntentResult {
        WaterLog.add()
        return .result()
    }
}
