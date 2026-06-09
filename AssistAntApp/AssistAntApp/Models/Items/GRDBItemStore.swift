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
        try dbQueue.write { db in try upsert(incoming, in: db) }
        backup.itemsDidChange()
    }

    /// Upsert within an existing transaction (no backup nudge). Shared by the
    /// public `upsert` and the batched `applyCalendarSync`.
    private func upsert(_ incoming: Item, in db: Database) throws {
        guard let ext = incoming.externalID else {
            throw ItemStoreError.upsertRequiresExternalID
        }
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
        from: CivilDate, to: CivilDate, keep: Set<String>,
        allowEmptyKeep: Bool
    ) throws {
        // An empty keep set retires every in-window item for the source. That is
        // almost always a degraded or empty upstream fetch (e.g. a transient API
        // hiccup returning nothing), not a real "the window is empty." Refuse
        // unless the caller explicitly opted in.
        if keep.isEmpty && !allowEmptyKeep {
            throw ItemStoreError.emptyKeepPruneRefused
        }
        try dbQueue.write { db in
            try pruneMissing(
                workspaceID: workspaceID, source: source,
                from: from, to: to, keep: keep, in: db)
        }
        backup.itemsDidChange()
    }

    /// Window prune within an existing transaction (no empty-keep guard, no
    /// backup nudge). Callers decide whether to prune — see `applyCalendarSync`.
    private func pruneMissing(
        workspaceID: String, source: String,
        from: CivilDate, to: CivilDate, keep: Set<String>, in db: Database
    ) throws {
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

    /// Apply a full calendar sync in ONE transaction: upsert every item, then
    /// prune the window. Atomic — the whole sync lands or none of it does.
    /// `prune` is skipped when the keep set is empty (unless `allowEmptyKeep`),
    /// so a degraded fetch can't wipe the window even if the flag is mis-set;
    /// the CLI also gates this upstream.
    func applyCalendarSync(
        items: [Item], workspaceID: String, source: String,
        from: CivilDate, to: CivilDate, keep: Set<String>,
        allowEmptyKeep: Bool, prune: Bool
    ) throws {
        let shouldPrune = prune && (!keep.isEmpty || allowEmptyKeep)
        try dbQueue.write { db in
            for item in items {
                try upsert(item, in: db)
            }
            if shouldPrune {
                try pruneMissing(
                    workspaceID: workspaceID, source: source,
                    from: from, to: to, keep: keep, in: db)
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

    func fetchActive(
        type: ItemType?, from: CivilDate, to: CivilDate?
    ) throws -> [Item] {
        try dbQueue.read { db in
            var sql = """
                deleted_at IS NULL AND iceboxed_at IS NULL
                AND scheduled_on IS NOT NULL AND scheduled_on >= ?
                """
            var args: [DatabaseValueConvertible] = [from.iso]
            if let to {
                sql += " AND scheduled_on <= ?"
                args.append(to.iso)
            }
            var request = Item.filter(sql: sql, arguments: StatementArguments(args))
            if let type {
                request = request.filter(sql: "type = ?", arguments: [type.rawValue])
            }
            return try request.order(sql: "scheduled_on, id").fetchAll(db)
        }
    }

    func observeActive(type: ItemType?) -> AnyPublisher<[Item], Error> {
        ValueObservation
            .tracking { db in try Self.activeRequest(type).fetchAll(db) }
            .publisher(in: dbQueue)
            .eraseToAnyPublisher()
    }

    // MARK: - Actionable items (todo / reminder / explore)

    func fetchActionable(asOf today: CivilDate) throws -> [Item] {
        try dbQueue.read { db in try Self.actionableRequest(today).fetchAll(db) }
    }

    func observeActionable(asOf today: CivilDate) -> AnyPublisher<[Item], Error> {
        ValueObservation
            .tracking { db in try Self.actionableRequest(today).fetchAll(db) }
            .publisher(in: dbQueue)
            .eraseToAnyPublisher()
    }

    func resolve(id: String) throws { try stampResolved(id: id, at: Date()) }
    func unresolve(id: String) throws { try stampResolved(id: id, at: nil) }

    private func stampResolved(id: String, at instant: Date?) throws {
        try dbQueue.write { db in
            guard var item = try Item.fetchOne(db, key: id) else { return }
            item.resolvedAt = instant
            item.updatedAt = Date()
            item.pending = true
            try item.update(db)
        }
        backup.itemsDidChange()
    }

    func reschedule(id: String, to scheduledOn: CivilDate?) throws {
        try dbQueue.write { db in
            guard var item = try Item.fetchOne(db, key: id) else { return }
            item.scheduledOn = scheduledOn
            item.updatedAt = Date()
            item.pending = true
            try item.update(db)
        }
        backup.itemsDidChange()
    }

    // Swap an actionable item's kind, preserving its payload (ActionableData is
    // identical across the three), identity, schedule, resolution, and position.
    func reclassify(id: String, to type: ItemType) throws {
        try dbQueue.write { db in
            guard var item = try Item.fetchOne(db, key: id) else { return }
            let data: ActionableData
            switch item.typeData {
            case .todo(let d), .reminder(let d), .explore(let d): data = d
            default: throw ItemStoreError.reclassifyRequiresActionable
            }
            switch type {
            case .todo: item.typeData = .todo(data)
            case .reminder: item.typeData = .reminder(data)
            case .explore: item.typeData = .explore(data)
            case .calendar: throw ItemStoreError.reclassifyRequiresActionable
            }
            item.type = item.typeData.kind
            item.updatedAt = Date()
            item.pending = true
            try item.update(db)
        }
        backup.itemsDidChange()
    }

    // Active actionable items that surface on `today`: not deleted/iceboxed/
    // resolved, and either unscheduled or scheduled on/before today (overdue
    // accumulates). `scheduled_on` is TEXT "YYYY-MM-DD" so `<=` is chronological.
    // Sort: manual position first (nulls last), then scheduled_on (nulls last),
    // then id.
    private static func actionableRequest(_ today: CivilDate) -> QueryInterfaceRequest<Item> {
        Item
            .filter(sql: """
                type IN ('todo', 'reminder', 'explore')
                AND deleted_at IS NULL AND iceboxed_at IS NULL
                AND resolved_at IS NULL
                AND (scheduled_on IS NULL OR scheduled_on <= ?)
                """, arguments: [today.iso])
            .order(sql: """
                position IS NULL, position,
                scheduled_on IS NULL, scheduled_on,
                id
                """)
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
