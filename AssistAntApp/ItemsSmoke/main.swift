import Foundation
import GRDB

// Sandboxed smoke check for the items model + store. Runs as its own process
// (no app, no AppDelegate, no sockets) against an in-memory database and a
// temp file, so it never touches real ~/.assist-ant data. Run via `make smoke`.
// Exits non-zero if any check fails.

var failures = 0

func check(_ name: String, _ body: () throws -> Bool) {
    do {
        if try body() {
            print("PASS  \(name)")
        } else {
            print("FAIL  \(name)")
            failures += 1
        }
    } catch {
        print("FAIL  \(name) — threw: \(error)")
        failures += 1
    }
}

/// A fresh in-memory store, migrated through the real migrator.
func makeStore() throws -> (GRDBItemStore, DatabaseQueue) {
    let queue = try DatabaseQueue()  // in-memory
    try ItemsDatabase.migrator.migrate(queue)
    return (GRDBItemStore(dbQueue: queue), queue)
}

func newItem(
    type: ItemType,
    typeData: ItemTypeData,
    source: String = "manual",
    externalID: String? = nil,
    title: String = "t",
    scheduledOn: CivilDate? = nil,
    iceboxedAt: Date? = nil
) -> Item {
    Item(
        id: UUIDv7.generate(), workspaceID: "local", type: type.rawValue,
        title: title, body: nil, source: source, externalID: externalID,
        typeData: typeData, iceboxedAt: iceboxedAt, deletedAt: nil,
        scheduledOn: scheduledOn,
        createdAt: Date(), updatedAt: Date(), serverUpdatedAt: nil, pending: false
    )
}

// 1. Round-trip every item type through the store (persists + reads back).
check("round-trip all item types") {
    let (store, _) = try makeStore()
    let items = [
        newItem(type: .calendar, typeData: .calendar(CalendarData(allDay: true))),
        newItem(type: .todo, typeData: .todo(ActionableData(listName: "errands"))),
        newItem(type: .reminder, typeData: .reminder(ActionableData())),
        newItem(type: .explore, typeData: .explore(ActionableData(
            externalURL: "https://example.com"))),
    ]
    for item in items { try store.create(item) }
    for item in items {
        guard let fetched = try store.fetch(id: item.id) else { return false }
        if fetched.typeData != item.typeData { return false }
        if fetched.type != item.typeData.kind { return false }
    }
    return true
}

// 2. An unrecognized kind round-trips losslessly as `.unknown`.
check("unknown type_data round-trips") {
    let json = #"{"kind":"habit","data":{"streak":3,"name":"floss"}}"#
        .data(using: .utf8)!
    let decoded = try JSONDecoder().decode(ItemTypeData.self, from: json)
    guard case .unknown(let kind, _) = decoded, kind == "habit" else { return false }
    let reencoded = try JSONEncoder().encode(decoded)
    let again = try JSONDecoder().decode(ItemTypeData.self, from: reencoded)
    return decoded == again
}

// 3. CivilDate is a zoneless YYYY-MM-DD string.
check("CivilDate encodes as YYYY-MM-DD") {
    let data = try JSONEncoder().encode(CivilDate(year: 2026, month: 6, day: 6))
    return String(data: data, encoding: .utf8) == "\"2026-06-06\""
}

// 4. Soft-deleted and iceboxed items are excluded from the active set.
check("soft-delete + icebox filtered from active") {
    let (store, _) = try makeStore()
    let keep = newItem(type: .todo, typeData: .todo(ActionableData()), title: "keep")
    let del = newItem(type: .todo, typeData: .todo(ActionableData()), title: "del")
    let ice = newItem(type: .todo, typeData: .todo(ActionableData()), title: "ice")
    try store.create(keep)
    try store.create(del)
    try store.create(ice)
    try store.softDelete(id: del.id)
    try store.setIceboxed(id: ice.id, true)
    let active = try store.fetchActive(type: nil)
    return active.count == 1 && active.first?.id == keep.id
}

// 5. Unique identity index rejects duplicate (workspace, source, external_id);
//    manual items (nil external_id) coexist freely.
check("unique identity index") {
    let (store, _) = try makeStore()
    let a = newItem(type: .calendar, typeData: .calendar(CalendarData()),
                    source: "gcal", externalID: "evt-1")
    try store.create(a)
    let dup = newItem(type: .calendar, typeData: .calendar(CalendarData()),
                      source: "gcal", externalID: "evt-1")
    var rejected = false
    do { try store.create(dup) } catch { rejected = true }
    // Two manual items with nil external_id must coexist.
    try store.create(newItem(type: .todo, typeData: .todo(ActionableData())))
    try store.create(newItem(type: .todo, typeData: .todo(ActionableData())))
    let manualCount = try store.fetchActive(type: .todo).count
    return rejected && manualCount == 2
}

// 6. VACUUM INTO produces a consistent, restorable snapshot.
check("VACUUM INTO snapshot is restorable") {
    let (store, queue) = try makeStore()
    for _ in 0..<5 {
        try store.create(newItem(type: .todo, typeData: .todo(ActionableData())))
    }
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("items-smoke-\(UUID().uuidString).db")
    try? FileManager.default.removeItem(at: tmp)
    try queue.writeWithoutTransaction { db in
        try db.execute(sql: "VACUUM INTO ?", arguments: [tmp.path])
    }
    let restored = try DatabaseQueue(path: tmp.path)
    let count = try restored.read { db in try Item.fetchCount(db) }
    try? FileManager.default.removeItem(at: tmp)
    return count == 5
}

// 7. The scheduled_on column persists and round-trips.
check("scheduled_on column round-trips") {
    let (store, _) = try makeStore()
    let date = CivilDate(year: 2026, month: 6, day: 6)
    let item = newItem(
        type: .calendar, typeData: .calendar(CalendarData(allDay: false)),
        source: "gcal", externalID: "sched-1", scheduledOn: date)
    try store.create(item)
    guard let fetched = try store.fetch(id: item.id) else { return false }
    return fetched.scheduledOn == date
}

// 8. Upsert is idempotent on (workspace, source, external_id): a second upsert
//    updates in place — one row, new values, stable id + createdAt.
check("upsert is idempotent") {
    let (store, _) = try makeStore()
    let a = newItem(type: .calendar, typeData: .calendar(CalendarData()),
                    source: "gcal", externalID: "e1", title: "v1")
    try store.upsert(a)
    guard let after1 = try store.fetchActive(type: .calendar)
        .first(where: { $0.externalID == "e1" }) else { return false }
    let b = newItem(type: .calendar, typeData: .calendar(CalendarData()),
                    source: "gcal", externalID: "e1", title: "v2")
    try store.upsert(b)
    let rows = try store.fetchActive(type: .calendar).filter { $0.externalID == "e1" }
    guard rows.count == 1, let after2 = rows.first else { return false }
    return after2.title == "v2"
        && after2.id == after1.id
        && after2.createdAt == after1.createdAt
}

// 9. Upsert resurrects a soft-deleted row (clears the tombstone) and refreshes
//    values, preserving id.
check("upsert resurrects a soft-deleted row") {
    let (store, _) = try makeStore()
    let a = newItem(type: .calendar, typeData: .calendar(CalendarData()),
                    source: "gcal", externalID: "r1", title: "v1")
    try store.upsert(a)
    try store.softDelete(id: a.id)
    guard try store.fetch(id: a.id)?.deletedAt != nil else { return false }
    let b = newItem(type: .calendar, typeData: .calendar(CalendarData()),
                    source: "gcal", externalID: "r1", title: "v2")
    try store.upsert(b)
    let rows = try store.fetchActive(type: .calendar).filter { $0.externalID == "r1" }
    guard rows.count == 1, let row = rows.first else { return false }
    return row.deletedAt == nil && row.title == "v2" && row.id == a.id
}

// 10. Prune is window-scoped by scheduled_on: only the in-window, non-kept item
//     is soft-deleted; items dated before/after the window survive.
check("prune is window-scoped") {
    let (store, _) = try makeStore()
    let before = newItem(type: .calendar, typeData: .calendar(CalendarData()),
                         source: "gcal", externalID: "before",
                         scheduledOn: CivilDate(year: 2026, month: 6, day: 1))
    let inside = newItem(type: .calendar, typeData: .calendar(CalendarData()),
                         source: "gcal", externalID: "inside",
                         scheduledOn: CivilDate(year: 2026, month: 6, day: 12))
    let after = newItem(type: .calendar, typeData: .calendar(CalendarData()),
                        source: "gcal", externalID: "after",
                        scheduledOn: CivilDate(year: 2026, month: 6, day: 20))
    try store.create(before); try store.create(inside); try store.create(after)
    try store.pruneMissing(
        workspaceID: "local", source: "gcal",
        from: CivilDate(year: 2026, month: 6, day: 10),
        to: CivilDate(year: 2026, month: 6, day: 17),
        keep: [], allowEmptyKeep: true)
    let beforeOK = try store.fetch(id: before.id)?.deletedAt == nil
    let insideDeleted = try store.fetch(id: inside.id)?.deletedAt != nil
    let afterOK = try store.fetch(id: after.id)?.deletedAt == nil
    return beforeOK && insideDeleted && afterOK
}

// 11. The workspace migration seats exactly one workspace with a non-empty
//     name and an opaque, lowercased UUID id.
check("workspace is seated by migration") {
    let queue = try DatabaseQueue()
    try ItemsDatabase.migrator.migrate(queue)
    let all = try queue.read { db in try Workspace.fetchAll(db) }
    guard all.count == 1, let ws = all.first else { return false }
    return !ws.name.isEmpty
        && ws.id == ws.id.lowercased()
        && UUID(uuidString: ws.id) != nil
}

// 12. Rows written under the legacy "local" scope are reassigned onto the
//     seated workspace; none remain as "local".
check("legacy 'local' rows backfill onto the workspace") {
    let queue = try DatabaseQueue()
    try ItemsDatabase.migrator.migrate(queue, upTo: "renameTenantToWorkspace")
    try queue.write { db in
        try db.execute(sql: """
            INSERT INTO items
              (id, workspace_id, type, title, source, type_data,
               created_at, updated_at, pending)
            VALUES
              ('legacy-1', 'local', 'todo', 't', 'manual',
               '{"kind":"todo","data":{}}',
               '2026-01-01 00:00:00.000', '2026-01-01 00:00:00.000', 0)
            """)
    }
    try ItemsDatabase.migrator.migrate(queue)
    guard let ws = try queue.read({ db in try Workspace.fetchOne(db) }) else {
        return false
    }
    let localCount = try queue.read { db in
        try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM items WHERE workspace_id = 'local'") ?? -1
    }
    let row = try queue.read { db in try Item.fetchOne(db, key: "legacy-1") }
    return localCount == 0 && row?.workspaceID == ws.id
}

// 13. WorkspaceStore renames in place: the name changes, the id is stable.
check("workspace store renames in place") {
    let queue = try DatabaseQueue()
    try ItemsDatabase.migrator.migrate(queue)
    let store = WorkspaceStore(dbQueue: queue)
    let before = try store.current()
    try store.rename(to: "Renamed")
    let after = try store.current()
    return after.name == "Renamed" && after.id == before.id
}

// 14. A window prune with an empty keep set is refused by default — the guard
//     against a degraded/empty upstream fetch wiping the window — and proceeds
//     only with the explicit opt-in.
check("empty-keep prune refused unless opted in") {
    let (store, _) = try makeStore()
    let item = newItem(type: .calendar, typeData: .calendar(CalendarData()),
                       source: "gcal", externalID: "ek1",
                       scheduledOn: CivilDate(year: 2026, month: 6, day: 12))
    try store.create(item)
    let from = CivilDate(year: 2026, month: 6, day: 10)
    let to = CivilDate(year: 2026, month: 6, day: 17)
    // Default: refused (throws), item survives.
    var refused = false
    do {
        try store.pruneMissing(
            workspaceID: "local", source: "gcal",
            from: from, to: to, keep: [], allowEmptyKeep: false)
    } catch ItemStoreError.emptyKeepPruneRefused {
        refused = true
    }
    let survived = try store.fetch(id: item.id)?.deletedAt == nil
    // Opt-in: proceeds, item retired.
    try store.pruneMissing(
        workspaceID: "local", source: "gcal",
        from: from, to: to, keep: [], allowEmptyKeep: true)
    let retired = try store.fetch(id: item.id)?.deletedAt != nil
    return refused && survived && retired
}

// 15. Today sidebar derivation: only today's calendar items, sorted by start,
//     with past events flagged.
check("today calendar rows: filter, sort, past flag") {
    var c = DateComponents()
    c.year = 2026; c.month = 6; c.day = 12; c.hour = 12; c.minute = 0
    let now = Calendar.current.date(from: c)!
    func at(_ h: Int) -> Date {
        Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: now)!
    }
    func cal(_ start: Date, _ end: Date) -> ItemTypeData {
        .calendar(CalendarData(startAt: start, endAt: end))
    }
    let today = CivilDate(now)
    let other = CivilDate(year: 2026, month: 6, day: 13)
    let past = newItem(type: .calendar, typeData: cal(at(9), at(10)),
                       source: "gcal", externalID: "p", scheduledOn: today)
    let soon = newItem(type: .calendar, typeData: cal(at(15), at(16)),
                       source: "gcal", externalID: "s", scheduledOn: today)
    let tomorrow = newItem(type: .calendar, typeData: cal(at(11), at(12)),
                           source: "gcal", externalID: "t", scheduledOn: other)
    let rows = TodayCalendar.rows(items: [soon, tomorrow, past], now: now)
    guard rows.count == 2 else { return false }
    return rows[0].item.id == past.id && rows[0].isPast
        && rows[1].item.id == soon.id && !rows[1].isPast
}

// 16. fetchActionable accumulates overdue + unscheduled items and surfaces
//     today's; excludes future-scheduled, resolved, and all calendar rows.
check("fetchActionable: accumulate overdue + unscheduled, exclude future/resolved/calendar") {
    let (store, _) = try makeStore()
    let today = CivilDate(year: 2026, month: 6, day: 12)
    func day(_ d: Int) -> CivilDate { CivilDate(year: 2026, month: 6, day: d) }

    let overdue = newItem(type: .todo, typeData: .todo(ActionableData()),
                          title: "overdue", scheduledOn: day(10))
    let onToday = newItem(type: .reminder, typeData: .reminder(ActionableData()),
                          title: "today", scheduledOn: today)
    let unscheduled = newItem(type: .explore, typeData: .explore(ActionableData()),
                              title: "unscheduled", scheduledOn: nil)
    let future = newItem(type: .todo, typeData: .todo(ActionableData()),
                         title: "future", scheduledOn: day(20))
    let cal = newItem(type: .calendar, typeData: .calendar(CalendarData()),
                      source: "gcal", externalID: "c1", title: "cal",
                      scheduledOn: today)
    for i in [overdue, onToday, unscheduled, future, cal] { try store.create(i) }

    let active = Set(try store.fetchActionable(asOf: today).map { $0.id })
    guard active == Set([overdue.id, onToday.id, unscheduled.id]) else { return false }

    try store.resolve(id: overdue.id)
    let afterResolve = Set(try store.fetchActionable(asOf: today).map { $0.id })
    return afterResolve == Set([onToday.id, unscheduled.id])
}

// 17. fetchActionable sort: explicit position first (in order), then the rest
//     by scheduled_on (nulls last).
check("fetchActionable sort: position, then scheduled_on (nulls last)") {
    let (store, _) = try makeStore()
    let today = CivilDate(year: 2026, month: 6, day: 12)
    func day(_ d: Int) -> CivilDate { CivilDate(year: 2026, month: 6, day: d) }

    var p2 = newItem(type: .todo, typeData: .todo(ActionableData()),
                     title: "p2", scheduledOn: day(11))
    p2.position = 2.0
    var p1 = newItem(type: .todo, typeData: .todo(ActionableData()),
                     title: "p1", scheduledOn: day(11))
    p1.position = 1.0
    let dated = newItem(type: .todo, typeData: .todo(ActionableData()),
                        title: "dated", scheduledOn: day(10))
    let undated = newItem(type: .todo, typeData: .todo(ActionableData()),
                          title: "undated", scheduledOn: nil)
    for i in [undated, dated, p2, p1] { try store.create(i) }

    let order = try store.fetchActionable(asOf: today).map { $0.title }
    return order == ["p1", "p2", "dated", "undated"]
}

// 18. Reschedule into the future drops an item off today; back to the past
//     returns it.
check("reschedule moves an item off and back onto today") {
    let (store, _) = try makeStore()
    let today = CivilDate(year: 2026, month: 6, day: 12)
    let item = newItem(type: .todo, typeData: .todo(ActionableData()),
                       scheduledOn: today)
    try store.create(item)
    try store.reschedule(id: item.id, to: CivilDate(year: 2026, month: 6, day: 20))
    let goneFromToday = try store.fetchActionable(asOf: today).isEmpty
    try store.reschedule(id: item.id, to: CivilDate(year: 2026, month: 6, day: 1))
    let backOnToday = try store.fetchActionable(asOf: today).contains { $0.id == item.id }
    return goneFromToday && backOnToday
}

// 19. Reclassify swaps the kind losslessly (payload, identity, schedule,
//     resolution, position all preserved) and rejects a calendar target.
check("reclassify swaps kind losslessly; rejects calendar") {
    let (store, _) = try makeStore()
    let today = CivilDate(year: 2026, month: 6, day: 12)
    let data = ActionableData(listName: "later", externalURL: "https://x.test")
    var item = newItem(type: .todo, typeData: .todo(data),
                       source: "linear", externalID: "ISSUE-1",
                       scheduledOn: today)
    item.position = 3.0
    try store.create(item)
    try store.resolve(id: item.id)   // a resolved item must survive reclassify
    try store.reclassify(id: item.id, to: .explore)

    guard let after = try store.fetch(id: item.id) else { return false }
    guard case .explore(let d) = after.typeData else { return false }
    // Split into sub-expressions: one long `&&` chain over many optionals
    // overwhelms the Swift type-checker.
    let payloadOK = (d == data)
    let identityOK = after.type == "explore"
        && after.source == "linear"
        && after.externalID == "ISSUE-1"
    let stateOK = after.scheduledOn == today
        && after.position == 3.0
        && after.resolvedAt != nil
    let preserved = payloadOK && identityOK && stateOK

    var rejected = false
    do { try store.reclassify(id: item.id, to: .calendar) }
    catch ItemStoreError.reclassifyRequiresActionable { rejected = true }
    return preserved && rejected
}

// Helpers for the actionable-sync checks below.
func lrow(
    _ ext: String, _ status: String, title: String = "t", body: String = "b",
    url: String = "https://linear.app/x", completedAt: String? = nil
) -> ActionableSyncBatch.ItemRow {
    ActionableSyncBatch.ItemRow(
        externalID: ext, title: title, body: body, url: url,
        statusType: status, completedAt: completedAt)
}

/// Fetch by external_id directly (works for iceboxed/resolved rows, which
/// fetchActive excludes).
func fetchByExt(_ queue: DatabaseQueue, _ ext: String) throws -> Item? {
    try queue.read { db in
        try Item.filter(sql: "external_id = ?", arguments: [ext]).fetchOne(db)
    }
}

// 20. Open issues (started/unstarted) are created as unscheduled todos.
check("actionable sync: open issues create as unscheduled todos") {
    let (store, _) = try makeStore()
    try store.applyActionableSync(
        rows: [lrow("FLEX-1", "started", title: "active"),
               lrow("FLEX-2", "unstarted", title: "todo")],
        workspaceID: "local", source: "linear",
        keep: ["FLEX-1", "FLEX-2"], reconcile: false, allowEmptyKeep: false)
    let items = try store.fetchActive(type: .todo)
    guard items.count == 2 else { return false }
    return items.allSatisfy {
        $0.type == "todo" && $0.source == "linear"
            && $0.scheduledOn == nil && $0.iceboxedAt == nil && $0.resolvedAt == nil
    }
}

// 21. A new backlog issue is created iceboxed (hidden from the active set).
check("actionable sync: backlog issue creates iceboxed") {
    let (store, queue) = try makeStore()
    try store.applyActionableSync(
        rows: [lrow("FLEX-3", "backlog")],
        workspaceID: "local", source: "linear",
        keep: ["FLEX-3"], reconcile: false, allowEmptyKeep: false)
    guard let item = try fetchByExt(queue, "FLEX-3") else { return false }
    let hiddenFromActive = try store.fetchActive(type: .todo).isEmpty
    return item.iceboxedAt != nil && item.type == "todo"
        && item.scheduledOn == nil && hiddenFromActive
}

// 22. Update refreshes title/body/url but preserves type and resolution.
check("actionable sync: update refreshes content, preserves type + resolution") {
    let (store, queue) = try makeStore()
    try store.applyActionableSync(
        rows: [lrow("FLEX-9", "started", title: "v1", body: "b1", url: "https://l/9")],
        workspaceID: "local", source: "linear",
        keep: ["FLEX-9"], reconcile: false, allowEmptyKeep: false)
    guard let created = try fetchByExt(queue, "FLEX-9") else { return false }
    try store.reclassify(id: created.id, to: .reminder)   // user adopts it
    try store.resolve(id: created.id)                     // and resolves it locally
    try store.applyActionableSync(
        rows: [lrow("FLEX-9", "started", title: "v2", body: "b2", url: "https://l/9b")],
        workspaceID: "local", source: "linear",
        keep: ["FLEX-9"], reconcile: false, allowEmptyKeep: false)
    guard let after = try store.fetch(id: created.id) else { return false }
    guard case .reminder(let d) = after.typeData else { return false }
    return after.title == "v2" && after.body == "b2"
        && d.externalURL == "https://l/9b"   // url refreshed
        && after.type == "reminder"          // type preserved
        && after.resolvedAt != nil           // never unresolved
}

// 23. Completed issues resolve on the completion day; a brand-new completed
//     issue is created already-resolved.
check("actionable sync: completed issues resolve on the completion day") {
    let (store, queue) = try makeStore()
    try store.applyActionableSync(
        rows: [lrow("FLEX-5", "started", title: "open")],
        workspaceID: "local", source: "linear",
        keep: ["FLEX-5"], reconcile: false, allowEmptyKeep: false)
    let completedAt = "2026-06-08T15:30:00.000Z"
    let expectedDay = CivilDate(
        ISO8601DateFormatter().date(from: "2026-06-08T15:30:00Z")!)
    try store.applyActionableSync(
        rows: [lrow("FLEX-5", "completed", title: "done", completedAt: completedAt),
               lrow("FLEX-6", "completed", title: "born done", completedAt: completedAt)],
        workspaceID: "local", source: "linear",
        keep: ["FLEX-5", "FLEX-6"], reconcile: false, allowEmptyKeep: false)
    guard let five = try fetchByExt(queue, "FLEX-5"),
          let six = try fetchByExt(queue, "FLEX-6") else { return false }
    return five.resolvedAt != nil && five.scheduledOn == expectedDay && five.title == "done"
        && six.resolvedAt != nil && six.scheduledOn == expectedDay && six.type == "todo"
}

// 24. Reconcile soft-deletes orphan todos, sparing resolved + reclassified.
check("actionable sync: reconcile soft-deletes orphan todos only") {
    let (store, queue) = try makeStore()
    try store.applyActionableSync(
        rows: [lrow("KEEP-1", "started"), lrow("ORPHAN-1", "started"),
               lrow("RESOLVED-1", "started"), lrow("ADOPTED-1", "started")],
        workspaceID: "local", source: "linear",
        keep: ["KEEP-1", "ORPHAN-1", "RESOLVED-1", "ADOPTED-1"],
        reconcile: false, allowEmptyKeep: false)
    guard let resolved = try fetchByExt(queue, "RESOLVED-1"),
          let adopted = try fetchByExt(queue, "ADOPTED-1") else { return false }
    try store.resolve(id: resolved.id)                  // resolved → history
    try store.reclassify(id: adopted.id, to: .explore)  // reclassified → adopted
    // Re-sync with only KEEP-1 assigned; the rest are orphaned.
    try store.applyActionableSync(
        rows: [lrow("KEEP-1", "started")],
        workspaceID: "local", source: "linear",
        keep: ["KEEP-1"], reconcile: true, allowEmptyKeep: false)
    guard let keep = try fetchByExt(queue, "KEEP-1"),
          let orphan = try fetchByExt(queue, "ORPHAN-1"),
          let res = try fetchByExt(queue, "RESOLVED-1"),
          let adp = try fetchByExt(queue, "ADOPTED-1") else { return false }
    return keep.deletedAt == nil       // in keep → kept
        && orphan.deletedAt != nil     // orphan todo → soft-deleted
        && res.deletedAt == nil        // resolved → spared (history)
        && adp.deletedAt == nil        // reclassified → spared (adopted)
}

// 25. An empty keep set is treated as degraded and skips reconcile.
check("actionable sync: empty keep skips reconcile") {
    let (store, queue) = try makeStore()
    try store.applyActionableSync(
        rows: [lrow("X-1", "started")],
        workspaceID: "local", source: "linear",
        keep: ["X-1"], reconcile: false, allowEmptyKeep: false)
    try store.applyActionableSync(
        rows: [], workspaceID: "local", source: "linear",
        keep: [], reconcile: true, allowEmptyKeep: false)
    guard let x = try fetchByExt(queue, "X-1") else { return false }
    return x.deletedAt == nil
}

// 26. fetchIceboxed returns active, unresolved, iceboxed actionables newest
//     first; excludes resolved, deleted, non-iceboxed, and calendar rows.
check("fetchIceboxed: iceboxed actionables only, newest first") {
    let (store, _) = try makeStore()
    func t(_ d: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(d)) }
    let old = newItem(type: .todo, typeData: .todo(ActionableData()),
                      title: "old", iceboxedAt: t(100))
    let new = newItem(type: .reminder, typeData: .reminder(ActionableData()),
                      title: "new", iceboxedAt: t(200))
    let active = newItem(type: .todo, typeData: .todo(ActionableData()),
                         title: "active")                       // not iceboxed
    let cal = newItem(type: .calendar, typeData: .calendar(CalendarData()),
                      source: "gcal", externalID: "c", iceboxedAt: t(300))
    for i in [old, new, active, cal] { try store.create(i) }
    let resolved = newItem(type: .todo, typeData: .todo(ActionableData()),
                           title: "resolved", iceboxedAt: t(400))
    try store.create(resolved)
    try store.completeActionable(id: resolved.id)               // resolved → excluded

    let ids = try store.fetchIceboxed().map { $0.id }
    return ids == [new.id, old.id]                              // newest first
}

// 27. completeActionable stamps resolved_at + scheduled_on=today, keeps
//     iceboxed_at, and drops the row from fetchIceboxed.
check("completeActionable: resolves + stamps today, keeps iceboxed") {
    let (store, _) = try makeStore()
    let item = newItem(type: .todo, typeData: .todo(ActionableData()),
                       iceboxedAt: Date())
    try store.create(item)
    try store.completeActionable(id: item.id)
    guard let after = try store.fetch(id: item.id) else { return false }
    let gone = try store.fetchIceboxed().isEmpty
    return after.resolvedAt != nil
        && after.scheduledOn == CivilDate(Date())
        && after.iceboxedAt != nil
        && gone
}

// 28. reopenActionable clears resolved_at and (when iceboxed) scheduled_on,
//     returning the row to fetchIceboxed.
check("reopenActionable: clears resolution + schedule when iceboxed") {
    let (store, _) = try makeStore()
    let item = newItem(type: .todo, typeData: .todo(ActionableData()),
                       iceboxedAt: Date())
    try store.create(item)
    try store.completeActionable(id: item.id)
    try store.reopenActionable(id: item.id)
    guard let after = try store.fetch(id: item.id) else { return false }
    let back = try store.fetchIceboxed().contains { $0.id == item.id }
    return after.resolvedAt == nil && after.scheduledOn == nil && back
}

// 29. moveToToday clears iceboxed_at + scheduled_on: leaves the icebox and
//     surfaces on today's actionables.
check("moveToToday: leaves icebox, accumulates on today") {
    let (store, _) = try makeStore()
    let today = CivilDate(year: 2026, month: 6, day: 12)
    let item = newItem(type: .todo, typeData: .todo(ActionableData()),
                       scheduledOn: CivilDate(year: 2026, month: 6, day: 1),
                       iceboxedAt: Date())
    try store.create(item)
    try store.moveToToday(id: item.id)
    guard let after = try store.fetch(id: item.id) else { return false }
    let goneFromIcebox = try store.fetchIceboxed().isEmpty
    let onToday = try store.fetchActionable(asOf: today).contains { $0.id == item.id }
    return after.iceboxedAt == nil && after.scheduledOn == nil
        && goneFromIcebox && onToday
}

// 30. IceboxGrouping: no-list group first, named lists A→Z, newest-first
//     within each.
check("IceboxGrouping: no-list first, named A→Z, newest within") {
    func t(_ d: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(d)) }
    func ice(_ list: String?, _ title: String, _ at: Int) -> Item {
        newItem(type: .todo, typeData: .todo(ActionableData(listName: list)),
                title: title, iceboxedAt: t(at))
    }
    let items = [
        ice("Zeta", "z-old", 10), ice("Zeta", "z-new", 20),
        ice("alpha", "a1", 50),
        ice(nil, "free-old", 1), ice(nil, "free-new", 2),
    ]
    let groups = IceboxGrouping.groups(items: items)
    let names = groups.map { $0.listName }
    let firstTitles = groups[0].items.map { $0.title }
    let zeta = groups.first { $0.listName == "Zeta" }!.items.map { $0.title }
    return names == [nil, "alpha", "Zeta"]                 // no-list, then A→Z (ci)
        && firstTitles == ["free-new", "free-old"]         // newest first
        && zeta == ["z-new", "z-old"]
}

print(failures == 0
    ? "\n✅ all smoke checks passed"
    : "\n❌ \(failures) smoke check(s) failed")
exit(failures == 0 ? 0 : 1)
