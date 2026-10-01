import Combine
import Foundation

@MainActor
final class CollectionFavoritesStore: ObservableObject {
    static let shared = CollectionFavoritesStore()
    @Published private(set) var collections: [OnlineCollection]
    private let defaults: UserDefaults
    private let key = "library.favoriteCollections"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        collections = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([OnlineCollection].self, from: $0) } ?? []
    }
    func contains(_ collection: OnlineCollection) -> Bool { collections.contains { $0.id == collection.id } }
    func toggle(_ collection: OnlineCollection) {
        if contains(collection) { collections.removeAll { $0.id == collection.id } } else { collections.insert(collection, at: 0) }
        if let data = try? JSONEncoder().encode(collections) { defaults.set(data, forKey: key) }
    }
}
