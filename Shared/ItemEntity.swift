import AppIntents
struct ItemEntity: AppEntity {
    let id: String
    let title: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Item"
    static var defaultQuery = ItemQuery()
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct ItemQuery: EntityQuery {
    private func all() -> [ItemEntity] {
        SharedSnapshot.load().items.map { ItemEntity(id: $0.id.uuidString, title: $0.title) }
    }
    func entities(for identifiers: [String]) async throws -> [ItemEntity] {
        all().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [ItemEntity] { all() }
    func defaultResult() async -> ItemEntity? { all().first }
}
