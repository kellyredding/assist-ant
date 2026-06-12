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

    // MARK: - Actionable sync (Linear → todos)

    /// Apply a Linear actionable sync in ONE transaction. Per row: create a new
    /// `todo` (backlog → iceboxed at creation; completed → resolved on the
    /// completion day) or update an existing item in place — refreshing only
    /// title/body/externalURL, preserving type, schedule, icebox, list, and
    /// position, and resolving it if it just completed but never unresolving.
    /// Then, when `reconcile` is set, soft-delete orphaned linear todos (active,
    /// unresolved, still `todo`, external_id not in `keep`), sparing resolved
    /// history and reclassified items. An empty keep set is treated as a
    /// degraded fetch and skips reconcile unless `allowEmptyKeep`.
    func applyActionableSync(
        rows: [ActionableSyncBatch.ItemRow],
        workspaceID: String, source: String,
        keep: Set<String>, reconcile: Bool, allowEmptyKeep: Bool
    ) throws {
        let shouldReconcile = reconcile && (!keep.isEmpty || allowEmptyKeep)
        try dbQueue.write { db in
            let now = Date()
            for row in rows {
                let completedAt = row.completedAt.flatMap(Self.parseISO)
                let existing = try Item
                    .filter(sql: "workspace_id = ? AND source = ? AND external_id = ?",
                            arguments: [workspaceID, source, row.externalID])
                    .fetchOne(db)
                if var item = existing {
                    // Update in place: refresh only the sync-owned fields.
                    item.title = row.title
                    item.body = row.body
                    item.typeData = Self.actionableWithURL(item.typeData, row.url)
                    // Resolve it if it just completed — but never unresolve.
                    if let completedAt, item.resolvedAt == nil {
                        item.resolvedAt = completedAt
                        item.scheduledOn = CivilDate(completedAt)
                    }
                    item.deletedAt = nil   // resurrect if a prior reconcile retired it
                    item.updatedAt = now
                    item.pending = true
                    try item.update(db)
                } else {
                    // Create as a todo: unscheduled; backlog → iceboxed now;
                    // completed → resolved on the completion day.
                    let item = Item(
                        id: UUIDv7.generate(),
                        workspaceID: workspaceID,
                        type: ItemType.todo.rawValue,
                        title: row.title,
                        body: row.body,
                        source: source,
                        externalID: row.externalID,
                        typeData: .todo(ActionableData(listName: nil, externalURL: row.url)),
                        iceboxedAt: row.statusType == "backlog" ? now : nil,
                        deletedAt: nil,
                        scheduledOn: completedAt.map { CivilDate($0) },
                        resolvedAt: completedAt,
                        position: nil,
                        createdAt: now,
                        updatedAt: now,
                        serverUpdatedAt: nil,
                        pending: true)
                    try item.insert(db)
                }
            }
            if shouldReconcile {
                try Self.reconcileOrphans(
                    workspaceID: workspaceID, source: source,
                    keep: keep, now: now, in: db)
            }
        }
        backup.itemsDidChange()
    }

    /// Soft-delete linear todos that fell out of the assigned set: active,
    /// unresolved, still typed `todo`, with an external_id not in `keep`.
    /// Resolved items (history) and reclassified ones (adopted) are left alone.
    private static func reconcileOrphans(
        workspaceID: String, source: String, keep: Set<String>,
        now: Date, in db: Database
    ) throws {
        let candidates = try Item
            .filter(sql: """
                workspace_id = ? AND source = ? AND type = ?
                AND deleted_at IS NULL AND resolved_at IS NULL
                AND external_id IS NOT NULL
                """, arguments: [workspaceID, source, ItemType.todo.rawValue])
            .fetchAll(db)
        for var item in candidates {
            guard let ext = item.externalID, !keep.contains(ext) else { continue }
            item.deletedAt = now
            item.updatedAt = now
            item.pending = true
            try item.update(db)
        }
    }

    /// Rewrap an actionable payload with a refreshed externalURL, preserving the
    /// kind (todo/reminder/explore) and listName. A linear item is always
    /// actionable; any other payload is returned unchanged.
    private static func actionableWithURL(
        _ data: ItemTypeData, _ url: String
    ) -> ItemTypeData {
        switch data {
        case .todo(let d): return .todo(ActionableData(listName: d.listName, externalURL: url))
        case .reminder(let d): return .reminder(ActionableData(listName: d.listName, externalURL: url))
        case .explore(let d): return .explore(ActionableData(listName: d.listName, externalURL: url))
        default: return data
        }
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    /// Parse an ISO-8601 instant, tolerating both fractional and whole seconds
    /// (Linear stamps milliseconds).
    private static func parseISO(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
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

    func fetchIceboxed() throws -> [Item] {
        try dbQueue.read { db in
            try Item
                .filter(sql: """
                    type IN ('todo', 'reminder', 'explore')
                    AND deleted_at IS NULL
                    AND iceboxed_at IS NOT NULL
                    AND resolved_at IS NULL
                    """)
                // iceboxed_at is a GRDB Date → TEXT "YYYY-MM-DD HH:MM:SS.SSS",
                // so DESC sorts newest-first chronologically.
                .order(sql: "iceboxed_at DESC, id")
                .fetchAll(db)
        }
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

    // Save the user-editable title and body in one write. The title is
    // trimmed and required — a blank value is ignored so the existing title
    // survives. The body trims (so editor-trailing blank lines don't
    // accumulate) and clears to NULL when blank. Type-agnostic: any item
    // carries both a title and a body.
    func setTitleAndBody(id: String, title: String, body: String?) throws {
        try dbQueue.write { db in
            guard var item = try Item.fetchOne(db, key: id) else { return }
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { item.title = t }
            let b = body?.trimmingCharacters(in: .whitespacesAndNewlines)
            item.body = (b?.isEmpty == false) ? b : nil
            item.updatedAt = Date()
            item.pending = true
            try item.update(db)
        }
        backup.itemsDidChange()
    }

    func completeActionable(id: String) throws {
        try dbQueue.write { db in
            guard var item = try Item.fetchOne(db, key: id) else { return }
            let now = Date()
            item.resolvedAt = now
            // Give an unscheduled item a definite day (the day it was finished)
            // so resolved items have a stable home and never accumulate; an item
            // that already carries a day keeps it.
            if item.scheduledOn == nil { item.scheduledOn = CivilDate(now) }
            item.updatedAt = now
            item.pending = true
            try item.update(db)
        }
        backup.itemsDidChange()
    }

    func reopenActionable(id: String) throws {
        try dbQueue.write { db in
            guard var item = try Item.fetchOne(db, key: id) else { return }
            // Resolution is the only state cleared; scheduled_on is durable, so
            // the row returns to whatever day it carried (icebox or schedule).
            item.resolvedAt = nil
            item.updatedAt = Date()
            item.pending = true
            try item.update(db)
        }
        backup.itemsDidChange()
    }

    // Rewrite the actionable payload with a new list name, preserving the kind
    // and external URL. A blank/whitespace name clears the list. Non-actionable
    // items have no list and are left untouched.
    func setListName(id: String, to listName: String?) throws {
        try dbQueue.write { db in
            guard var item = try Item.fetchOne(db, key: id) else { return }
            let trimmed = listName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = (trimmed?.isEmpty == false) ? trimmed : nil
            switch item.typeData {
            case .todo(let d):
                item.typeData = .todo(ActionableData(listName: value, externalURL: d.externalURL))
            case .reminder(let d):
                item.typeData = .reminder(ActionableData(listName: value, externalURL: d.externalURL))
            case .explore(let d):
                item.typeData = .explore(ActionableData(listName: value, externalURL: d.externalURL))
            default:
                return   // calendar / unknown have no list name
            }
            item.updatedAt = Date()
            item.pending = true
            try item.update(db)
        }
        backup.itemsDidChange()
    }

    func knownListNames() throws -> [String] {
        try dbQueue.read { db in
            // listName lives inside the type_data JSON, so pull it with
            // json_extract; DISTINCT + the NULL/blank filter keep the list to
            // names actually in use. NOCASE only orders — exact-case variants
            // remain distinct values, which is correct (they are stored that way).
            try String.fetchAll(db, sql: """
                SELECT DISTINCT json_extract(type_data, '$.data.listName') AS list
                FROM items
                WHERE type IN ('todo', 'reminder', 'explore')
                  AND deleted_at IS NULL
                  AND list IS NOT NULL AND TRIM(list) <> ''
                ORDER BY list COLLATE NOCASE
                """)
        }
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
