import Foundation
import SwiftUI

/// Shared limits for item geofences and trusted places, in metres.
enum Geofence {
    static let range: ClosedRange<Double> = 10...1500
    static func clamp(_ r: Double) -> Double { min(max(r, range.lowerBound), range.upperBound) }
}

/// Radius slider used for items and trusted places. Logarithmic, so the small end (10 to 100 m)
/// gets as much travel as the big end and you can actually land on small values.
struct GeofenceSlider: View {
    var title: String = "Geofence radius"
    @Binding var radius: Double
    @AppStorage(DistanceUnit.storageKey) private var unit: DistanceUnit = .localeDefault

    private let lo = Geofence.range.lowerBound
    private let hi = Geofence.range.upperBound

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title) {
                Text(unit.format(radius)).monospacedDigit()
            }
            Slider(value: Binding(get: { position(radius) },
                                  set: { radius = Geofence.clamp(unit.snap(value(at: $0))) }),
                   in: 0...1) {
                Text(title)
            } minimumValueLabel: {
                Text(unit.format(lo)).font(.caption2).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text(unit.format(hi)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func position(_ r: Double) -> Double { log(Geofence.clamp(r) / lo) / log(hi / lo) }
    private func value(at t: Double) -> Double { lo * pow(hi / lo, t) }
}
