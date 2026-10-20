import Foundation
import CoreLocation

enum PlaceMode: String, Codable {
    case remind   // alert if you leave this place without the item
    case ignore   // never alert here; you leave it here on purpose
}

/// Places you care about leaving the item at. Two modes, like a smarter Find My:
/// remind (don't forget it when you go) or ignore (fine to leave it here).
struct Place: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var lat: Double
    var lon: Double
    var radius: Double = 150
    var mode: PlaceMode = .remind
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

    func add(name: String, at loc: CLLocation, mode: PlaceMode = .remind, radius: Double = 150) {
        places.append(Place(name: name.isEmpty ? "Place" : name,
                            lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                            radius: radius, mode: mode))
        changed()
    }

    func remove(_ p: Place) {
        places.removeAll { $0.id == p.id }
        changed()
    }

    func setMode(_ p: Place, _ mode: PlaceMode) {
        guard let i = places.firstIndex(where: { $0.id == p.id }) else { return }
        places[i].mode = mode
        changed()
    }

    /// Geofence radius for this place, metres.
    func setRadius(_ p: Place, _ radius: Double) {
        guard let i = places.firstIndex(where: { $0.id == p.id }) else { return }
        places[i].radius = Geofence.clamp(radius)
        changed()
    }

    func rename(_ p: Place, _ name: String) {
        guard let i = places.firstIndex(where: { $0.id == p.id }) else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        places[i].name = n.isEmpty ? "Place" : n
        changed()
    }

    /// Any place (either mode) that this coordinate falls inside. Used to suppress the generic
    /// item-left-behind alert, since trusted places have their own leave logic.
    func containing(_ coord: CLLocationCoordinate2D) -> Place? {
        let point = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        return places.first { p in
            point.distance(from: CLLocation(latitude: p.lat, longitude: p.lon)) <= p.radius
        }
    }

    private var pendingSync: DispatchWorkItem?

    private func changed() {
        if let d = try? JSONEncoder().encode(places) { UserDefaults.standard.set(d, forKey: key) }
        // The radius slider fires continuously; re-register regions with iOS once it settles.
        pendingSync?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            LocationRecorder.shared.syncPlaceRegions(self.places)
        }
        pendingSync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}
