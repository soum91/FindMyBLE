import SwiftUI
import UIKit

/// Today's water, logged by hand. The widget's + button writes to the same log.
final class WaterModel: ObservableObject {
    static let shared = WaterModel()
    @Published private(set) var log = WaterLog.load()

    private init() {
        // The widget may have logged a glass while the app was in the background.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.reload() }
    }

    func reload() { log = WaterLog.load() }

    func add() { WaterLog.add(); reload() }
    func undo() { WaterLog.undoLast(); reload() }

    func setGoal(_ ml: Double) { var l = WaterLog.load(); l.goal = ml; l.save(); reload() }
    func setGlass(_ ml: Double) { var l = WaterLog.load(); l.glass = ml; l.save(); reload() }
}

struct WaterCard: View {
    @ObservedObject var w = WaterModel.shared
    @AppStorage(DistanceUnit.storageKey) private var unit: DistanceUnit = .localeDefault

    var body: some View {
        let today = w.log.total()
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(Color.blue.opacity(0.18), lineWidth: 6)
                Circle().trim(from: 0, to: w.log.progress)
                    .stroke(Color.blue.gradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(duration: 0.5), value: w.log.progress)
                ItemGlyph(kind: .bottle, tint: .blue)
                    .frame(width: 22, height: 22)
                    .colorMultiply(.blue)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text("Water Today").font(.subheadline).foregroundStyle(.secondary)
                Text(unit.volume(today)).font(.title3.weight(.semibold)).monospacedDigit()
                    .contentTransition(.numericText())
                Text("of \(unit.volume(w.log.goal))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation { w.add() }
            } label: {
                Label("+\(unit.volume(w.log.glass))", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .contextMenu {
                Button("Undo Last", systemImage: "arrow.uturn.backward") { withAnimation { w.undo() } }
                    .disabled(today == 0)
            }
        }
        .padding(.vertical, 6)
        .onAppear { w.reload() }
    }
}

/// Goal and glass size, in the Me tab.
struct WaterSettings: View {
    @ObservedObject var w = WaterModel.shared
    @AppStorage(DistanceUnit.storageKey) private var unit: DistanceUnit = .localeDefault

    var body: some View {
        Section {
            Stepper(value: Binding(get: { w.log.goal }, set: { w.setGoal($0) }),
                    in: 500...6000, step: unit == .metric ? 250 : 236.588) {
                LabeledContent("Daily goal") { Text(unit.volume(w.log.goal)) }
            }
            Stepper(value: Binding(get: { w.log.glass }, set: { w.setGlass($0) }),
                    in: 50...1500, step: unit == .metric ? 50 : 29.5735) {
                LabeledContent("Each tap adds") { Text(unit.volume(w.log.glass)) }
            }
            Button("Undo Last Entry", role: .destructive) { w.undo() }
                .disabled(w.log.total() == 0)
        } header: {
            Text("Water")
        } footer: {
            Text("Logged by hand, from here or the widget's + button. A full LARQ bottle is 500 ml (17 oz) or 740 ml (25 oz) depending on size, so set \"Each tap adds\" to that if you count bottles.")
        }
    }
}

/// Lets you see whether the widget can actually read the app's data after sideloading.
struct WidgetDiagnostics: View {
    var body: some View {
        Section {
            LabeledContent("Widget data sharing", value: AppGroup.isShared ? "Working" : "Not available")
            if !AppGroup.isShared {
                Text("The sideload removed the App Group, so the widget can't see the app. Reinstall with app extensions kept on (AltStore, SideStore and Sideloadly all have the option).")
                    .font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("Widget")
        } footer: {
            Text("The widget only shows what the app saw. iOS doesn't let widgets run Bluetooth, so the connection itself is held by the app in the background. Don't force-quit it.")
        }
    }
}
