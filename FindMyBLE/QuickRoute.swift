import SwiftUI
@MainActor final class FindMyBLERoute: ObservableObject {
    static let shared = FindMyBLERoute()
    @Published var finding: UUID?
}
