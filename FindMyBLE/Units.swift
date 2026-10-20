import Foundation
import SwiftUI

/// Display unit for distances. Everything is stored in metres; this only changes what you see.
enum DistanceUnit: String, CaseIterable, Identifiable {
    case metric, imperial
    var id: String { rawValue }
    var label: String { self == .metric ? "Metres" : "Feet" }

    static let storageKey = "distanceUnit"
    /// Follows the phone's region until you pick one.
    static var localeDefault: DistanceUnit { Locale.current.measurementSystem == .us ? .imperial : .metric }

    func format(_ meters: Double) -> String {
        switch self {
        case .metric:
            if meters < 1000 { return "\(Int(meters.rounded())) m" }
            return String(format: meters < 10_000 ? "%.1f km" : "%.0f km", meters / 1000)
        case .imperial:
            let ft = meters * 3.28084
            if ft < 1000 { return "\(Int(ft.rounded())) ft" }
            let mi = meters / 1609.344
            return String(format: mi < 10 ? "%.2f mi" : "%.1f mi", mi)
        }
    }

    /// Round a metre value to a step that looks clean in this unit (5 ft / 5 m when small,
    /// coarser as it grows), so the slider lands on 10 m or 50 ft rather than 47.3.
    func snap(_ meters: Double) -> Double {
        switch self {
        case .metric:
            let step: Double = meters < 50 ? 5 : meters < 200 ? 10 : meters < 500 ? 25 : 50
            return (meters / step).rounded() * step
        case .imperial:
            let ft = meters * 3.28084
            let step: Double = ft < 200 ? 5 : ft < 1000 ? 25 : 100
            return (ft / step).rounded() * step / 3.28084
        }
    }
}

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
