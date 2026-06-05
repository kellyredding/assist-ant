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
