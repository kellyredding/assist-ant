import Foundation
import Combine

enum ItemStoreError: Error {
    /// `upsert` keys on `external_id`; an item without one must use `create`.
    case upsertRequiresExternalID
}

/// The seam the rest of the app uses to read and mutate items. A GRDB-backed
/// local implementation exists today; the sync engine plugs in behind this
/// same protocol later.
protocol ItemStore {
    func create(_ item: Item) throws
    func update(_ item: Item) throws

    /// Insert-or-update keyed on `(tenant, source, external_id)`. Resurrects a
    /// soft-deleted row (clears `deletedAt`) and refreshes values; preserves the
    /// existing `id` and `createdAt`. Requires a non-nil `externalID`.
    func upsert(_ item: Item) throws

    func softDelete(id: String) throws
    func setIceboxed(id: String, _ iceboxed: Bool) throws

    /// Window-scoped reconcile: soft-delete active items for `source` whose
    /// `scheduledOn` is within `[from, to]` and whose `externalID` is not in
    /// `keep`. Items outside the window are untouched.
    func pruneMissing(
        tenantID: String, source: String,
        from: CivilDate, to: CivilDate, keep: Set<String>
    ) throws

    func fetch(id: String) throws -> Item?

    /// Active items: not soft-deleted and not iceboxed. `type == nil` = all types.
    func fetchActive(type: ItemType?) throws -> [Item]

    /// Reactive stream of active items, re-emitted on every relevant DB change.
    func observeActive(type: ItemType?) -> AnyPublisher<[Item], Error>
}
