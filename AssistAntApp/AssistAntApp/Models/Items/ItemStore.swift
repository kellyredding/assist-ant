import Foundation
import Combine

/// The seam the rest of the app uses to read and mutate items. A GRDB-backed
/// local implementation exists today; the sync engine plugs in behind this
/// same protocol later.
protocol ItemStore {
    func create(_ item: Item) throws
    func update(_ item: Item) throws
    func softDelete(id: String) throws
    func setIceboxed(id: String, _ iceboxed: Bool) throws
    func fetch(id: String) throws -> Item?

    /// Active items: not soft-deleted and not iceboxed. `type == nil` = all types.
    func fetchActive(type: ItemType?) throws -> [Item]

    /// Reactive stream of active items, re-emitted on every relevant DB change.
    func observeActive(type: ItemType?) -> AnyPublisher<[Item], Error>
}
