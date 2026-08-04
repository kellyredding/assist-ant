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

    func undelete(id: String) throws {
        try dbQueue.write { db in
            guard var item = try Item.fetchOne(db, key: id) else { return }
            let now = Date()
            item.deletedAt = nil
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
    /// history and reclassified items.
    ///
    /// Reconcile is withheld on a degraded fetch: an empty keep set, or a keep
    /// set that matches none of the rows it could retire. Either is answered by
    /// skipping the retirement half while every upsert still lands, because
    /// deferring a retirement costs one cycle of stale rows and self-heals,
    /// where performing a wrong one cost 31 items and a manual afternoon.
    /// `allowEmptyKeep` / `allowFullTurnover` are the deliberate overrides.
    @discardableResult
    func applyActionableSync(
        rows: [ActionableSyncBatch.ItemRow],
        workspaceID: String, source: String,
        keep: Set<String>, reconcile: Bool, allowEmptyKeep: Bool,
        allowFullTurnover: Bool = false
    ) throws -> ActionableSyncOutcome {
        var outcome = ActionableSyncOutcome()
        try dbQueue.write { db in
            let now = Date()

            // Sampled BEFORE the upsert loop, and the ordering IS the guard.
            // The loop below inserts rows whose keys are all in `keep`, so a
            // match measured afterwards is guaranteed and meaningless: the run
            // that retired 31 items would have "matched" on the 33 it had just
            // created, and the guard would have passed while doing nothing.
            let priorKeys = try String.fetchAll(
                db,
                sql: "SELECT external_id FROM items WHERE \(Self.reconcileCandidateSQL)",
                arguments: [workspaceID, source, ItemType.todo.rawValue])
            // A full turnover is a non-empty candidate set that the incoming
            // keys miss entirely. On a first sync `priorKeys` is empty — there
            // is nothing to protect, so the guard stays out of the way rather
            // than appearing to fire constantly on a fresh install.
            let fullTurnover = !priorKeys.isEmpty
                && !priorKeys.contains(where: keep.contains)

            outcome.priorCandidates = priorKeys.count
            if reconcile, keep.isEmpty, !allowEmptyKeep {
                outcome.reconcileWithheld = true
                outcome.withheldReason = .emptyFetch
            } else if reconcile, fullTurnover, !allowFullTurnover {
                outcome.reconcileWithheld = true
                outcome.withheldReason = .fullTurnover
            }

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
                    // Resolution mirrors `completed_at` in BOTH directions. It
                    // previously only ever set it, so an issue that regressed
                    // Done → Backlog upstream stayed flagged resolved here —
                    // wrong on its own, and worse because reconcile spares
                    // resolved rows, which pinned it permanently out of reach.
                    //
                    // One signal, not two: the create branch already keys
                    // resolution purely on `completed_at`, so consulting
                    // `status_type` here would let the two disagree for an issue
                    // marked completed with no timestamp.
                    //
                    // Un-resolving restores the item to the active world, so its
                    // placement is re-derived the way a create derives it rather
                    // than left holding the artifacts the completion left behind.
                    if let completedAt {
                        if item.resolvedAt == nil {
                            item.resolvedAt = completedAt
                            item.scheduledOn = CivilDate(completedAt)
                        }
                    } else if let wasResolved = item.resolvedAt {
                        item.resolvedAt = nil
                        // The day goes only when it is still the stamp resolution
                        // wrote. `completeActionable` overwrites any past or
                        // future day with the completion date, so a resolved
                        // item's day is that stamp — there is no pre-completion
                        // day left to protect. A day that DIFFERS was therefore
                        // set deliberately after completing (rescheduling stays
                        // available on a resolved row), and that survives.
                        //
                        // The two cases collide when someone scheduled an item
                        // for the very day it completed, and that costs nothing:
                        // an unscheduled item and one scheduled for a past day
                        // both surface on Today.
                        if item.scheduledOn == CivilDate(wasResolved) {
                            item.scheduledOn = nil
                        }
                        // A regression into backlog is a deferral, and this is
                        // the only moment sync may say so. Icebox membership is
                        // otherwise a local decision with no Linear counterpart,
                        // so gating on the un-resolve is what keeps a deliberate
                        // "remove from icebox" on a live backlog row from being
                        // undone on every sync.
                        if row.statusType == "backlog" { item.iceboxedAt = now }
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
            if reconcile, !outcome.reconcileWithheld {
                outcome.retired = try Self.reconcileOrphans(
                    workspaceID: workspaceID, source: source,
                    keep: keep, now: now, in: db)
            }
        }
        backup.itemsDidChange()
        return outcome
    }

    /// The rows reconcile is entitled to retire: active, unresolved, still typed
    /// `todo`, and carrying an external key. Resolved items (history) and
    /// reclassified ones (adopted) fall outside it.
    ///
    /// One definition, because the full-turnover guard has to measure exactly
    /// the set reconcile would act on. A second copy of this predicate is a
    /// guard that silently stops guarding the moment the two drift.
    /// Binds `workspace_id`, `source`, `type` in that order.
    private static let reconcileCandidateSQL = """
        workspace_id = ? AND source = ? AND type = ?
        AND deleted_at IS NULL AND resolved_at IS NULL
        AND external_id IS NOT NULL
        """

    /// Soft-delete linear todos that fell out of the assigned set. Returns how
    /// many were retired, so the sync can report what it actually did rather
    /// than what it was asked to do.
    private static func reconcileOrphans(
        workspaceID: String, source: String, keep: Set<String>,
        now: Date, in db: Database
    ) throws -> Int {
        let candidates = try Item
            .filter(sql: reconcileCandidateSQL,
                    arguments: [workspaceID, source, ItemType.todo.rawValue])
            .fetchAll(db)
        var retired = 0
        for var item in candidates {
            guard let ext = item.externalID, !keep.contains(ext) else { continue }
            item.deletedAt = now
            item.updatedAt = now
            item.pending = true
            try item.update(db)
            retired += 1
        }
        return retired
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

    func fetchTodaySidebar(asOf today: CivilDate) throws -> [Item] {
        try dbQueue.read { db in try Self.todaySidebarRequest(today).fetchAll(db) }
    }

    func observeTodaySidebar(asOf today: CivilDate) -> AnyPublisher<[Item], Error> {
        ValueObservation
            .tracking { db in try Self.todaySidebarRequest(today).fetchAll(db) }
            .publisher(in: dbQueue)
            .eraseToAnyPublisher()
    }

    /// The scratch feed, newest first, split by resolved state.
    ///
    /// Two disjoint feeds rather than one list with resolved rows struck in
    /// place: the pane's toggle swaps between them, which keeps the working
    /// buffer from accumulating dead weight indefinitely. Completed entries
    /// order by *when they were resolved*, since that is the axis you scan when
    /// reviewing them — the open feed orders by creation, which is the axis you
    /// scan when looking for something you parked.
    func observeScratch(resolved: Bool) -> AnyPublisher<[Item], Error> {
        ValueObservation
            .tracking { db in try Self.scratchRequest(resolved).fetchAll(db) }
            .publisher(in: dbQueue)
            .eraseToAnyPublisher()
    }

    func fetchScratch(resolved: Bool) throws -> [Item] {
        try dbQueue.read { db in try Self.scratchRequest(resolved).fetchAll(db) }
    }

    private static func scratchRequest(
        _ resolved: Bool
    ) -> QueryInterfaceRequest<Item> {
        Item
            .filter(sql: """
                type = 'scratch' AND deleted_at IS NULL
                AND resolved_at IS \(resolved ? "NOT NULL" : "NULL")
                """)
            .order(sql: resolved
                ? "resolved_at DESC, id DESC"
                : "created_at DESC, id DESC")
    }

    func fetchIceboxed() throws -> [Item] {
        try dbQueue.read { db in
            try Item
                .filter(sql: """
                    type IN (\(ItemType.actionableSQLList))
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

    func fetchTrashed() throws -> [Item] {
        try dbQueue.read { db in
            try Item
                // Scratch joins the actionables here, and Trash is the one
                // surface where that is intended: a discarded note is
                // recoverable on the same terms as a discarded to-do. Every
                // other predicate in this file leaves scratch out, which is why
                // this one names it explicitly rather than widening the shared
                // list.
                .filter(sql: """
                    type IN (\(ItemType.actionableSQLList), 'scratch')
                    AND deleted_at IS NOT NULL
                    """)
                // deleted_at is a GRDB Date → TEXT "YYYY-MM-DD HH:MM:SS.SSS",
                // so DESC sorts newest-first chronologically.
                .order(sql: "deleted_at DESC, id")
                .fetchAll(db)
        }
    }

    // Every non-deleted actionable, any icebox / resolved state — the source for
    // `actionable-item list --state active`. Distinct from fetchActive (excludes
    // iceboxed) and fetchIceboxed (iceboxed + unresolved only).
    func fetchAllActionable() throws -> [Item] {
        try dbQueue.read { db in
            try Item
                .filter(sql: """
                    type IN (\(ItemType.actionableSQLList)) AND deleted_at IS NULL
                    """)
                .order(sql: "id")
                .fetchAll(db)
        }
    }

    func iceboxSummary(asOf today: CivilDate) throws -> IceboxSummary {
        try dbQueue.read { db in
            // Same set as fetchIceboxed; aggregate in Swift (the box is small).
            let rows = try Item
                .filter(sql: """
                    type IN (\(ItemType.actionableSQLList))
                    AND deleted_at IS NULL
                    AND iceboxed_at IS NOT NULL
                    AND resolved_at IS NULL
                    """)
                .fetchAll(db)
            var byKind: [String: Int] = [:]
            var oldest: Date?
            let cutoff = today.adding(days: -30)
            var olderThan30 = 0
            for item in rows {
                byKind[item.type, default: 0] += 1
                guard let at = item.iceboxedAt else { continue }
                if oldest == nil || at < oldest! { oldest = at }
                if CivilDate(at) < cutoff { olderThan30 += 1 }
            }
            let oldestAgeDays = oldest.map {
                Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 0
            }
            return IceboxSummary(
                total: rows.count, byKind: byKind,
                oldestAgeDays: oldestAgeDays, olderThan30: olderThan30)
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
            // Resolving always re-homes the item to today, overwriting any past or
            // future day: the completion date is the honest record of when it was
            // finished, so a resolved item never sits on another day (it can't show
            // as "completed" on a future date that hasn't arrived). iceboxed_at is
            // left untouched — a reopen reverts cleanly back into the icebox, so the
            // resolution and icebox membership are reversible, but the date is not.
            item.scheduledOn = CivilDate(now)
            item.updatedAt = now
            item.pending = true
            try item.update(db)
        }
        backup.itemsDidChange()
    }

    func reopenActionable(id: String) throws {
        try dbQueue.write { db in
            guard var item = try Item.fetchOne(db, key: id) else { return }
            // Resolution is the only state cleared; scheduled_on and iceboxed_at
            // are durable. Completion stamped scheduled_on to that day, so a reopen
            // leaves the item on today and — if it was iceboxed — back in the icebox
            // at its original position.
            item.resolvedAt = nil
            item.updatedAt = Date()
            item.pending = true
            try item.update(db)
        }
        backup.itemsDidChange()
    }

    // Rewrite the actionable payload with a new list name, preserving the kind
    // and external URL. A blank/whitespace name clears the list. Every other
    // kind is left untouched — a scratch note's list lives in its own payload
    // and is written by setScratchListName, so the two never contend for a row.
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

    // Set or clear a note's list. A blank/whitespace name clears it; any other
    // kind is left untouched (an actionable's list is setListName's).
    //
    // Mutates the payload in place rather than rebuilding it, unlike the
    // actionable setters: ScratchData is the type a later note-only field lands
    // on, and a rebuild would drop that field the first time one exists.
    func setScratchListName(id: String, to listName: String?) throws {
        try dbQueue.write { db in
            guard var item = try Item.fetchOne(db, key: id) else { return }
            guard case .scratch(var data) = item.typeData else { return }
            let trimmed = listName?.trimmingCharacters(in: .whitespacesAndNewlines)
            data.listName = (trimmed?.isEmpty == false) ? trimmed : nil
            item.typeData = .scratch(data)
            item.updatedAt = Date()
            item.pending = true
            try item.update(db)
        }
        backup.itemsDidChange()
    }

    // Set or clear an actionable's external URL, preserving the kind and list
    // name (mirrors setListName). A blank/nil clears it. Non-actionable items
    // (calendar / unknown) carry no editable URL here and are left untouched.
    func setExternalURL(id: String, to url: String?) throws {
        try dbQueue.write { db in
            guard var item = try Item.fetchOne(db, key: id) else { return }
            let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = (trimmed?.isEmpty == false) ? trimmed : nil
            switch item.typeData {
            case .todo(let d):
                item.typeData = .todo(ActionableData(listName: d.listName, externalURL: value))
            case .reminder(let d):
                item.typeData = .reminder(ActionableData(listName: d.listName, externalURL: value))
            case .explore(let d):
                item.typeData = .explore(ActionableData(listName: d.listName, externalURL: value))
            default:
                return   // calendar / unknown have no editable URL here
            }
            item.updatedAt = Date()
            item.pending = true
            try item.update(db)
        }
        backup.itemsDidChange()
    }

    // Set or clear the manual sort position used by drag-reorder. A single
    // write; the grouping sort reads `position` (nulls last) so the row lands
    // where dropped.
    func setPosition(id: String, to position: Double?) throws {
        try dbQueue.write { db in
            guard var item = try Item.fetchOne(db, key: id) else { return }
            item.position = position
            item.updatedAt = Date()
            item.pending = true
            try item.update(db)
        }
        backup.itemsDidChange()
    }

    // Renormalize a group: write many positions in one transaction. Used when a
    // fractional midpoint collides or a neighbor is unranked, so the whole group
    // gets evenly spaced ranks at once.
    func setPositions(_ positions: [String: Double]) throws {
        guard !positions.isEmpty else { return }
        try dbQueue.write { db in
            for (id, pos) in positions {
                guard var item = try Item.fetchOne(db, key: id) else { continue }
                item.position = pos
                item.updatedAt = Date()
                item.pending = true
                try item.update(db)
            }
        }
        backup.itemsDidChange()
    }

    func knownListNames() throws -> [String] {
        try dbQueue.read { db in
            // listName lives inside the type_data JSON, so pull it with
            // json_extract; DISTINCT + the NULL/blank filter keep the list to
            // names actually in use. Order in Swift via ActionableListSort so a
            // leading emoji/symbol is ignored, matching the list views; exact-case
            // variants remain distinct values (they are stored that way).
            //
            // Scratch joins the actionables because the names are ONE namespace:
            // the same `$.data.listName` path in both payloads, so a name a note
            // introduced suggests for a to-do and the reverse, and filing work
            // beside the thought that started it is one word typed once. Named
            // explicitly rather than widening the shared actionable list — every
            // other predicate that reads it still means work only, the way
            // fetchTrashed names it for its own reason.
            let names = try String.fetchAll(db, sql: """
                SELECT DISTINCT json_extract(type_data, '$.data.listName') AS list
                FROM items
                WHERE type IN (\(ItemType.actionableSQLList), 'scratch')
                  AND deleted_at IS NULL
                  AND list IS NOT NULL AND TRIM(list) <> ''
                """)
            return names.sorted(by: ActionableListSort.less)
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
            // Neither is a label swap. Calendar is read-only, and turning a
            // note into real work needs a title composed from its body — a
            // conversion, not a reclassification. `convertScratch` is that
            // conversion; refusing the pair here keeps the two paths from being
            // mistaken for one, since only one of them can compose.
            case .calendar, .scratch:
                throw ItemStoreError.reclassifyRequiresActionable
            }
            item.type = item.typeData.kind
            item.updatedAt = Date()
            item.pending = true
            try item.update(db)
        }
        backup.itemsDidChange()
    }

    // Promote a scratch note into real work: the SAME row becomes an actionable
    // item, keeping its id, created_at, and source, swapping `type` and the
    // `.scratch` payload for the actionable pair, and taking a title, body, and
    // link the caller composed. `reclassify` refuses this pair on purpose — a
    // note is body-only and its title is derived from that body, so promoting
    // one needs a title (and usually an edited body) that only the caller can
    // write. That composition is the entire difference between the two calls.
    //
    // In place rather than create-and-trash, for two reasons. A copy silently
    // loses the id, which a selection or an agent transcript may already refer
    // to, and created_at, which is when the thought was captured rather than
    // when it was finally shaped. And in-place conversion is self-idempotent:
    // the caller's slash command can be retyped on an unconfirmed submit, and a
    // second run lands on `convertRequiresScratch` instead of minting a
    // duplicate.
    func convertScratch(
        id: String, to kind: ItemType, title: String, body: String?,
        externalURL: String?
    ) throws {
        // Checked before opening the transaction, like pruneMissing's empty-keep
        // guard: a bad target is the caller's mistake, not a write to roll back.
        guard ItemType.actionableCases.contains(kind) else {
            throw ItemStoreError.convertRequiresActionableTarget
        }
        try dbQueue.write { db in
            guard var item = try Item.fetchOne(db, key: id) else { return }
            guard case .scratch = item.typeData else {
                throw ItemStoreError.convertRequiresScratch
            }
            // A discarded note is not quietly revived as live work: put it back
            // first, so recovery and promotion stay two visible steps.
            guard item.deletedAt == nil else {
                throw ItemStoreError.convertTrashedRefused
            }
            // The actionable payload the note becomes: the note's own list, plus
            // the link the caller followed. The list transfers unconditionally,
            // with nothing to pass to decline it — filing a thought under a list
            // already said where the work belongs, and promoting it out of that
            // group would scatter the set the notes were collected into. Read
            // through scratchListName, so the name is the normalized one the feed
            // grouped under, and read HERE: the switch below rewrites typeData,
            // and after it the note's list is gone.
            var data = ActionableData(listName: item.scratchListName)
            if let externalURL, !externalURL.isEmpty {
                data.externalURL = externalURL
            }
            switch kind {
            case .todo: item.typeData = .todo(data)
            case .reminder: item.typeData = .reminder(data)
            case .explore: item.typeData = .explore(data)
            // Unreachable — the actionableCases guard already refused these.
            // Spelled out rather than defaulted so a sixth ItemType stops
            // compiling here instead of quietly becoming a legal destination.
            case .calendar, .scratch:
                throw ItemStoreError.convertRequiresActionableTarget
            }
            item.type = item.typeData.kind
            // Trimmed and required: a blank title leaves the note's derived one
            // standing rather than writing an empty NOT NULL column, the same
            // rule setTitleAndBody follows.
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTitle.isEmpty { item.title = trimmedTitle }
            // nil means "carry the note over as it stands". Unlike
            // setTitleAndBody, nil does NOT clear here — the body IS the note,
            // and a conversion that named only a title would otherwise discard
            // the text it was composed from. An explicit blank still clears.
            if let body {
                let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
                item.body = trimmedBody.isEmpty ? nil : trimmedBody
            }
            // `setIceboxed` is type-agnostic, so a scratch row CAN carry an
            // iceboxed stamp even though no UI path sets one. Cleared here
            // because a stale stamp would route the converted item into the
            // Icebox instead of onto Today, invisibly.
            item.iceboxedAt = nil
            // Nothing else moves. resolved_at survives, so a completed note
            // promotes as completed work that reopenActionable can revive;
            // scheduled_on and position are nil on a note, so the converted item
            // lands unscheduled on Today exactly like a fresh capture.
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
                type IN (\(ItemType.actionableSQLList))
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

    // The Today-sidebar working set. Same base as `actionableRequest` (active
    // actionables, not scheduled into the future — overdue accumulates), but it
    // KEEPS items resolved today instead of excluding all resolved ones, so a
    // Done/Dismiss in the sidebar stays struck until the day rolls over. The
    // resolved-today test reads the LOCAL civil date of `resolved_at`:
    // `resolved_at` is a UTC datetime ("YYYY-MM-DD HH:MM:SS.SSS"), and
    // SQLite's `date(_, 'localtime')` converts it to the local day before the
    // compare — matching `CivilDate(_, in: .current)` used elsewhere. The
    // not-future guard (`scheduled_on <= today`) still drops reschedule-to-
    // future. Same sort as actionableRequest.
    private static func todaySidebarRequest(_ today: CivilDate) -> QueryInterfaceRequest<Item> {
        Item
            .filter(sql: """
                type IN (\(ItemType.actionableSQLList))
                AND deleted_at IS NULL AND iceboxed_at IS NULL
                AND (scheduled_on IS NULL OR scheduled_on <= ?)
                AND (resolved_at IS NULL OR date(resolved_at, 'localtime') = ?)
                """, arguments: [today.iso, today.iso])
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
