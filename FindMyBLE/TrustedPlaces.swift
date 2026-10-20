import Foundation
import CoreLocation

/// Places where leaving the item is fine (home, work). Like Find My's trusted locations:
/// no left-behind alert fires when the item is left inside one of these.
struct Place: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var lat: Double
    var lon: Double
    var radius: Double = 150
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

final class TrustedPlaces: ObservableObject {
    static let shared = TrustedPlaces()
    private let key = "trustedPlaces"

    @Published private(set) var places: [Place] = []

    private init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let p = try? JSONDecoder().decode([Place].self, from: d) {
            places = p
        }
    }

    func add(name: String, at loc: CLLocation, radius: Double = 150) {
        let p = Place(name: name.isEmpty ? "Place" : name,
                      lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, radius: radius)
        places.append(p)
        save()
    }

    func remove(_ p: Place) {
        places.removeAll { $0.id == p.id }
        save()
    }

    /// Is this coordinate inside any trusted place?
    func contains(_ coord: CLLocationCoordinate2D) -> Bool {
        let point = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        return places.contains { p in
            point.distance(from: CLLocation(latitude: p.lat, longitude: p.lon)) <= p.radius
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(places) { UserDefaults.standard.set(d, forKey: key) }
    }
}
