import Foundation
import Combine
import GRDB

/// GRDB-backed local `ItemStore`. Every mutation stamps timestamps locally
/// (pre-sync, single writer), marks the row `pending` (the push outbox), and
/// nudges the backup coordinator. Reads exclude soft-deleted and iceboxed rows.
final class GRDBItemStore: ItemStore {
    static let shared = GRDBItemStore()

    private let dbQueue: DatabaseQueue
    private let backup: ItemBackupCoordinator

    private init() {
        self.dbQueue = ItemsDatabase.shared.dbQueue
        self.backup = .shared
    }

    /// Test seam: inject a migrated (e.g. in-memory) queue and optional backup.
    init(dbQueue: DatabaseQueue, backup: ItemBackupCoordinator = .shared) {
        self.dbQueue = dbQueue
        self.backup = backup
    }

    func create(_ item: Item) throws {
        var item = item
        let now = Date()
        item.createdAt = now
        item.updatedAt = now
        item.pending = true
        item.type = item.typeData.kind
        try dbQueue.write { db in
            try item.insert(db)
        }
        backup.itemsDidChange()
    }

    func update(_ item: Item) throws {
        var item = item
        item.updatedAt = Date()
        item.pending = true
        item.type = item.typeData.kind
        try dbQueue.write { db in
            try item.update(db)
        }
        backup.itemsDidChange()
    }

    func upsert(_ incoming: Item) throws {
        guard let ext = incoming.externalID else {
            throw ItemStoreError.upsertRequiresExternalID
        }
        try dbQueue.write { db in
            let existing = try Item
                .filter(sql: "workspace_id = ? AND source = ? AND external_id = ?",
                        arguments: [incoming.workspaceID, incoming.source, ext])
                .fetchOne(db)
            var row = incoming
            let now = Date()
            row.type = row.typeData.kind
            row.updatedAt = now
            row.pending = true
            row.deletedAt = nil          // resurrect on re-accept
            if let existing {
                row.id = existing.id
                row.createdAt = existing.createdAt
                try row.update(db)
            } else {
                row.createdAt = now
                try row.insert(db)
            }
        }
        backup.itemsDidChange()
    }

    func softDelete(id: String) throws {
        try dbQueue.write { db in
            guard var item = try Item.fetchOne(db, key: id) else { return }
            let now = Date()
            item.deletedAt = now
            item.updatedAt = now
            item.pending = true
            try item.update(db)
        }
        backup.itemsDidChange()
    }

    func setIceboxed(id: String, _ iceboxed: Bool) throws {
        try dbQueue.write { db in
            guard var item = try Item.fetchOne(db, key: id) else { return }
            item.iceboxedAt = iceboxed ? Date() : nil
            item.updatedAt = Date()
            item.pending = true
            try item.update(db)
        }
        backup.itemsDidChange()
    }

    // Reconcile WITHIN the sync window only: soft-delete active items for
    // `source` whose `scheduled_on` is in [from, to] and whose external_id is
    // not in `keep`. Items outside the window — past, or beyond the horizon —
    // are never touched, so history is preserved. `scheduled_on` is TEXT
    // "YYYY-MM-DD", so the range compare is lexicographic (= chronological).
    func pruneMissing(
        workspaceID: String, source: String,
        from: CivilDate, to: CivilDate, keep: Set<String>
    ) throws {
        try dbQueue.write { db in
            let inWindow = try Item
                .filter(sql: """
                    workspace_id = ? AND source = ? AND deleted_at IS NULL
                    AND scheduled_on IS NOT NULL
                    AND scheduled_on >= ? AND scheduled_on <= ?
                    """, arguments: [workspaceID, source, from.iso, to.iso])
                .fetchAll(db)
            let now = Date()
            for var item in inWindow {
                guard let ext = item.externalID, !keep.contains(ext) else { continue }
                item.deletedAt = now
                item.updatedAt = now
                item.pending = true
                try item.update(db)
            }
        }
        backup.itemsDidChange()
    }

    func fetch(id: String) throws -> Item? {
        try dbQueue.read { db in try Item.fetchOne(db, key: id) }
    }

    func fetchActive(type: ItemType?) throws -> [Item] {
        try dbQueue.read { db in try Self.activeRequest(type).fetchAll(db) }
    }

    func observeActive(type: ItemType?) -> AnyPublisher<[Item], Error> {
        ValueObservation
            .tracking { db in try Self.activeRequest(type).fetchAll(db) }
            .publisher(in: dbQueue)
            .eraseToAnyPublisher()
    }

    // Active = not soft-deleted and not iceboxed. Ordered by id, which for
    // UUIDv7 approximates creation order.
    private static func activeRequest(_ type: ItemType?) -> QueryInterfaceRequest<Item> {
        var request = Item.filter(sql: "deleted_at IS NULL AND iceboxed_at IS NULL")
        if let type {
            request = request.filter(sql: "type = ?", arguments: [type.rawValue])
        }
        return request.order(sql: "id")
    }
}
