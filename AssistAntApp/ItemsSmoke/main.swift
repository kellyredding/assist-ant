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
    iceboxedAt: Date? = nil,
    resolvedAt: Date? = nil,
    body: String? = nil
) -> Item {
    Item(
        id: UUIDv7.generate(), workspaceID: "local", type: type.rawValue,
        title: title, body: body, source: source, externalID: externalID,
        typeData: typeData, iceboxedAt: iceboxedAt, deletedAt: nil,
        scheduledOn: scheduledOn, resolvedAt: resolvedAt,
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

// 13b. The persona-name migration backfills the seated row to the default.
check("workspace seats with the default persona") {
    let queue = try DatabaseQueue()
    try ItemsDatabase.migrator.migrate(queue)
    let ws = try WorkspaceStore(dbQueue: queue).current()
    return ws.personaName == Workspace.defaultPersonaName
}

// 13c. WorkspaceStore.setPersonaName round-trips, preserving the id.
check("workspace store sets persona in place") {
    let queue = try DatabaseQueue()
    try ItemsDatabase.migrator.migrate(queue)
    let store = WorkspaceStore(dbQueue: queue)
    let before = try store.current()
    try store.setPersonaName("assist-ant-personal")
    let after = try store.current()
    return after.personaName == "assist-ant-personal" && after.id == before.id
}

// 13d. Workspace spend config: defaults seed sane, the three setters round-trip,
//      and the SpendState JSON column survives a write/read cycle.
check("workspace spend: defaults + setters + SpendState round-trip") {
    let queue = try DatabaseQueue()
    try ItemsDatabase.migrator.migrate(queue)
    let store = WorkspaceStore(dbQueue: queue)
    let before = try store.current()
    guard !before.spendShow, before.spendStaleHours == 24, before.spendState == nil
    else { return false }
    try store.setSpendShow(true)
    try store.setSpendStaleHours(6)
    try store.setSpendState(SpendState(
        primary: "$392 today", secondary: "$2.7k mo", capturedAt: Date(),
        variants: [.init(label: "Month to Date", body: "📊 …")]))
    let after = try store.current()
    return after.spendShow && after.spendStaleHours == 6
        && after.spendState?.primary == "$392 today"
        && after.spendState?.variants.first?.label == "Month to Date"
        && after.spendState?.variants.count == 1
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

// 18b. fetchTodaySidebar keeps the Today working set: unresolved (unscheduled +
//      overdue + today) PLUS items resolved TODAY — including an overdue item
//      completed today, whose scheduled_on stays in the past — while dropping
//      future-scheduled, prior-day completions, and iceboxed rows. Uses the real
//      local today so the `date(resolved_at,'localtime')` compare lines up with
//      the stamped instants.
check("fetchTodaySidebar: keeps resolved-today (incl. overdue completion), drops prior-day/future/iceboxed") {
    let (store, _) = try makeStore()
    let today = CivilDate(Date())
    let yesterday = today.adding(days: -1)
    let tomorrow = today.adding(days: 1)
    let now = Date()
    let longAgo = Date(timeIntervalSinceNow: -3 * 86_400)   // ~3 days back

    // Unresolved members of today's set.
    let unscheduled = newItem(type: .todo, typeData: .todo(ActionableData()),
                              title: "unscheduled")
    let overdueOpen = newItem(type: .reminder, typeData: .reminder(ActionableData()),
                              title: "overdueOpen", scheduledOn: yesterday)
    // Resolved members: completed today stay (even when the day is in the past,
    // as an overdue completion keeps its original scheduled_on).
    let doneToday = newItem(type: .todo, typeData: .todo(ActionableData()),
                            title: "doneToday", scheduledOn: today, resolvedAt: now)
    let doneOverdue = newItem(type: .reminder, typeData: .reminder(ActionableData()),
                              title: "doneOverdue", scheduledOn: yesterday, resolvedAt: now)
    // Dropped: scheduled into the future, completed on a prior day, iceboxed.
    let future = newItem(type: .todo, typeData: .todo(ActionableData()),
                         title: "future", scheduledOn: tomorrow)
    let donePriorDay = newItem(type: .todo, typeData: .todo(ActionableData()),
                               title: "donePriorDay", scheduledOn: yesterday, resolvedAt: longAgo)
    let iceboxed = newItem(type: .explore, typeData: .explore(ActionableData()),
                           title: "iceboxed", iceboxedAt: now)

    for i in [unscheduled, overdueOpen, doneToday, doneOverdue, future, donePriorDay, iceboxed] {
        try store.create(i)
    }
    let ids = Set(try store.fetchTodaySidebar(asOf: today).map { $0.id })
    return ids == Set([unscheduled.id, overdueOpen.id, doneToday.id, doneOverdue.id])
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

// 27. completeActionable stamps resolved_at; it stamps today only when the item
//     is unscheduled, never overriding an existing day. Keeps iceboxed_at and
//     drops resolved rows from fetchIceboxed.
check("completeActionable: preserves a set day, stamps today when unscheduled") {
    let (store, _) = try makeStore()
    let day = CivilDate(year: 2026, month: 6, day: 20)
    let dated = newItem(type: .todo, typeData: .todo(ActionableData()),
                        scheduledOn: day, iceboxedAt: Date())
    let bare = newItem(type: .todo, typeData: .todo(ActionableData()), iceboxedAt: Date())
    try store.create(dated); try store.create(bare)
    try store.completeActionable(id: dated.id)
    try store.completeActionable(id: bare.id)
    guard let d = try store.fetch(id: dated.id),
          let b = try store.fetch(id: bare.id) else { return false }
    let gone = try store.fetchIceboxed().isEmpty            // both resolved → excluded
    return d.resolvedAt != nil && d.scheduledOn == day && d.iceboxedAt != nil
        && b.resolvedAt != nil && b.scheduledOn == CivilDate(Date())
        && gone
}

// 28. reopenActionable clears resolved_at only; scheduled_on is durable, so a
//     row returns to whatever day it carried and back into fetchIceboxed.
check("reopenActionable: clears resolution, preserves schedule") {
    let (store, _) = try makeStore()
    let day = CivilDate(year: 2026, month: 6, day: 20)
    let item = newItem(type: .todo, typeData: .todo(ActionableData()),
                       scheduledOn: day, iceboxedAt: Date())
    try store.create(item)
    try store.completeActionable(id: item.id)   // resolved; day preserved (20th)
    try store.reopenActionable(id: item.id)
    guard let after = try store.fetch(id: item.id) else { return false }
    let back = try store.fetchIceboxed().contains { $0.id == item.id }
    return after.resolvedAt == nil && after.scheduledOn == day && back
}

// 29. setIceboxed(false) (Remove from Icebox) clears iceboxed_at only; the row
//     falls back to its scheduled day, or Today when it has none.
check("setIceboxed(false): leaves icebox, falls back to its day / today") {
    let (store, _) = try makeStore()
    let today = CivilDate(year: 2026, month: 6, day: 12)
    let future = CivilDate(year: 2026, month: 6, day: 20)
    let dated = newItem(type: .todo, typeData: .todo(ActionableData()),
                        scheduledOn: future, iceboxedAt: Date())
    let bare = newItem(type: .todo, typeData: .todo(ActionableData()), iceboxedAt: Date())
    try store.create(dated); try store.create(bare)
    try store.setIceboxed(id: dated.id, false)
    try store.setIceboxed(id: bare.id, false)
    guard let d = try store.fetch(id: dated.id),
          let b = try store.fetch(id: bare.id) else { return false }
    let onSchedule = try store.fetchActive(type: nil, from: future, to: future)
        .contains { $0.id == dated.id }
    let onToday = try store.fetchActionable(asOf: today).contains { $0.id == bare.id }
    return d.iceboxedAt == nil && d.scheduledOn == future && onSchedule
        && b.iceboxedAt == nil && b.scheduledOn == nil && onToday
}

// 30. ActionableGrouping: no-list group first, named lists A→Z, newest-first
//     within each.
check("ActionableGrouping: no-list first, named A→Z, newest within") {
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
    let groups = ActionableGrouping.groups(items: items)
    let names = groups.map { $0.listName }
    let firstTitles = groups[0].items.map { $0.title }
    let zeta = groups.first { $0.listName == "Zeta" }!.items.map { $0.title }
    return names == [nil, "alpha", "Zeta"]                 // no-list, then A→Z (ci)
        && firstTitles == ["free-new", "free-old"]         // newest first
        && zeta == ["z-new", "z-old"]
}

// 31. knownListNames: distinct, non-empty list names from non-deleted
//     actionables, case-insensitively sorted; blanks/nil/deleted excluded.
check("knownListNames: distinct, non-empty, excludes deleted") {
    let (store, _) = try makeStore()
    func mk(_ list: String?) -> Item {
        newItem(type: .todo, typeData: .todo(ActionableData(listName: list)))
    }
    let a = mk("Ideas"); let b = mk("Ideas"); let c = mk("Backlog")
    let emoji = mk("🐜 AAA")
    let blank = mk("   "); let none = mk(nil); let gone = mk("Archive")
    for i in [a, b, c, emoji, blank, none, gone] { try store.create(i) }
    try store.softDelete(id: gone.id)
    // Text-keyed order (ActionableListSort): "🐜 AAA" sorts by "AAA", ahead of
    // "Backlog".
    return try store.knownListNames() == ["🐜 AAA", "Backlog", "Ideas"]
}

// 32. setListName sets a name (preserving the external URL), surfaces it in
//     knownListNames, and a blank value clears it.
check("setListName: sets, preserves URL, surfaces in known, blank clears") {
    let (store, _) = try makeStore()
    let item = newItem(
        type: .reminder,
        typeData: .reminder(ActionableData(externalURL: "https://x.test")))
    try store.create(item)
    try store.setListName(id: item.id, to: "Follow-ups")
    guard let set = try store.fetch(id: item.id),
          case .reminder(let d) = set.typeData else { return false }
    let known = try store.knownListNames()
    try store.setListName(id: item.id, to: "   ")   // blank → cleared
    guard let cleared = try store.fetch(id: item.id),
          case .reminder(let d2) = cleared.typeData else { return false }
    return d.listName == "Follow-ups"
        && d.externalURL == "https://x.test"
        && known.contains("Follow-ups")
        && d2.listName == nil
}

// 33. setTitleAndBody trims and stores both; a blank body clears to NULL, and
//     a blank title is ignored (the existing title survives).
check("setTitleAndBody: sets (trimmed), blank body clears, blank title kept") {
    let (store, _) = try makeStore()
    let item = newItem(type: .todo, typeData: .todo(ActionableData()), title: "orig")
    try store.create(item)
    try store.setTitleAndBody(id: item.id, title: "  new title  ", body: "  new body  ")
    guard let a = try store.fetch(id: item.id) else { return false }
    try store.setTitleAndBody(id: item.id, title: "   ", body: "   ")
    guard let b = try store.fetch(id: item.id) else { return false }
    return a.title == "new title" && a.body == "new body"
        && b.title == "new title" && b.body == nil
}

// 34. setIceboxed(true) (Move to Icebox) stamps iceboxed_at and KEEPS
//     scheduled_on; the flag supersedes the schedule, hiding the item from the
//     active schedule window while it sits in the icebox.
check("setIceboxed(true): enters icebox, keeps the scheduled day") {
    let (store, _) = try makeStore()
    let day = CivilDate(year: 2026, month: 6, day: 20)
    let item = newItem(type: .todo, typeData: .todo(ActionableData()), scheduledOn: day)
    try store.create(item)
    try store.setIceboxed(id: item.id, true)
    guard let after = try store.fetch(id: item.id) else { return false }
    let inIcebox = try store.fetchIceboxed().contains { $0.id == item.id }
    let offSchedule = try store.fetchActive(type: nil, from: day, to: day)
        .contains { $0.id == item.id } == false
    return after.iceboxedAt != nil && after.scheduledOn == day && inIcebox && offSchedule
}

// 35. resolveVerb accumulates across kinds: to-do/explore → "Done", reminder →
//     "Dismiss", a mixed batch → "Done / Dismiss".
check("resolveVerb: per-kind and mixed-batch accumulation") {
    let todo = newItem(type: .todo, typeData: .todo(ActionableData()))
    let explore = newItem(type: .explore, typeData: .explore(ActionableData()))
    let reminder = newItem(type: .reminder, typeData: .reminder(ActionableData()))
    return ItemActionState.verb(for: [todo, explore]) == "Done"
        && ItemActionState.verb(for: [reminder]) == "Dismiss"
        && ItemActionState.verb(for: [todo, reminder]) == "Done / Dismiss"
}

// 36. ItemActionState.allIceboxed drives the Icebox slot label; true only when
//     every item is iceboxed.
check("ItemActionState: allIceboxed across a set") {
    let iceboxed = newItem(type: .todo, typeData: .todo(ActionableData()), iceboxedAt: Date())
    let onToday = newItem(type: .todo, typeData: .todo(ActionableData()))
    return ItemActionState([iceboxed]).allIceboxed
        && !ItemActionState([iceboxed, onToday]).allIceboxed
}

// 37. ActionableListNavigation.visibleIDs: top→bottom across groups, skipping the
//     items inside any collapsed group — named OR the no-list group (keyed by id).
check("ActionableListNavigation.visibleIDs: order, skips collapsed") {
    func ice(_ list: String?, _ title: String, _ at: Int) -> Item {
        newItem(type: .todo, typeData: .todo(ActionableData(listName: list)),
                title: title, iceboxedAt: Date(timeIntervalSince1970: TimeInterval(at)))
    }
    // Groups derive as: no-list (free1 newer, free2), "alpha" (a1), "Zeta" (z1).
    let items = [ice(nil, "free1", 2), ice(nil, "free2", 1),
                 ice("alpha", "a1", 50), ice("Zeta", "z1", 60)]
    let groups = ActionableGrouping.groups(items: items)
    let id = Dictionary(uniqueKeysWithValues:
        groups.flatMap(\.items).map { ($0.title, $0.id) })
    let noListId = groups.first { $0.listName == nil }!.id
    let all = ActionableListNavigation.visibleIDs(groups, collapsed: [])
    let collapsed = ActionableListNavigation.visibleIDs(groups, collapsed: ["Zeta"])
    let noList = ActionableListNavigation.visibleIDs(groups, collapsed: [noListId])
    return all == ["free1", "free2", "a1", "z1"].compactMap { id[$0] }
        && collapsed == ["free1", "free2", "a1"].compactMap { id[$0] }
        && noList == ["a1", "z1"].compactMap { id[$0] }
}

// 38. ActionableListNavigation.step: +1/-1 clamps at the ends (no wrap); nil/unknown
//     current resolves to first (down) or last (up); empty order → nil.
check("ActionableListNavigation.step: clamps, nil/unknown → first/last") {
    let order = ["a", "b", "c"]
    return ActionableListNavigation.step(from: "a", by: 1, in: order) == "b"
        && ActionableListNavigation.step(from: "c", by: 1, in: order) == "c"     // clamp end
        && ActionableListNavigation.step(from: "a", by: -1, in: order) == "a"    // clamp start
        && ActionableListNavigation.step(from: nil, by: 1, in: order) == "a"     // nil → first
        && ActionableListNavigation.step(from: nil, by: -1, in: order) == "c"    // nil → last
        && ActionableListNavigation.step(from: "x", by: 1, in: order) == "a"     // unknown → first
        && ActionableListNavigation.step(from: "z", by: 1, in: []) == nil        // empty → nil
}

// 39. ActionableListNavigation.idsInGroup: the *a target — every id in the group holding
//     the focused row; empty when nothing is focused.
check("ActionableListNavigation.idsInGroup: scopes to focused row's group") {
    func ice(_ list: String?, _ title: String) -> Item {
        newItem(type: .todo, typeData: .todo(ActionableData(listName: list)), title: title)
    }
    let items = [ice(nil, "free"), ice("alpha", "a1"), ice("alpha", "a2"), ice("Zeta", "z1")]
    let groups = ActionableGrouping.groups(items: items)
    let alpha = groups.first { $0.listName == "alpha" }!
    let a1 = alpha.items.first { $0.title == "a1" }!
    return Set(ActionableListNavigation.idsInGroup(of: a1.id, groups)) == Set(alpha.items.map { $0.id })
        && ActionableListNavigation.idsInGroup(of: nil, groups).isEmpty
}

// 40. ScheduleAgenda.days: a day splits into time-sorted calendar events and
//     actionables grouped into sublists (no-list first, then named); calendar
//     events never enter the groups.
check("ScheduleAgenda.days: splits events + actionables, time-sorts, groups") {
    let day = CivilDate(year: 2026, month: 6, day: 15)
    func at(_ h: Int) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 15; c.hour = h
        return Calendar.current.date(from: c)!
    }
    let evtLate = newItem(type: .calendar,
                          typeData: .calendar(CalendarData(startAt: at(14), endAt: at(15))),
                          source: "gcal", externalID: "late", scheduledOn: day)
    let evtEarly = newItem(type: .calendar,
                           typeData: .calendar(CalendarData(startAt: at(9), endAt: at(10))),
                           source: "gcal", externalID: "early", scheduledOn: day)
    let bare = newItem(type: .todo, typeData: .todo(ActionableData()),
                       title: "bare", scheduledOn: day)
    let listed = newItem(type: .reminder, typeData: .reminder(ActionableData(listName: "Errands")),
                         title: "listed", scheduledOn: day)
    let days = ScheduleAgenda.days(items: [evtLate, evtEarly, bare, listed], from: day, today: day)
    guard let d = days.first(where: { $0.date == day }) else { return false }
    let eventsSorted = d.events.map { $0.externalID } == ["early", "late"]
    let noEventsInGroups = d.actionableGroups.flatMap(\.items)
        .allSatisfy { !ScheduleAgenda.isCalendar($0) }
    let groupNames = d.actionableGroups.map { $0.listName }
    return eventsSorted && noEventsInGroups && groupNames == [nil, "Errands"]
}

// 41. The schedule's fetch surfaces scheduled actionables alongside events,
//     keeps resolved ones (struck history, day preserved), excludes iceboxed.
check("fetchActive(from:to:): scheduled actionables incl. resolved, excl. iceboxed") {
    let (store, _) = try makeStore()
    let day = CivilDate(year: 2026, month: 6, day: 15)
    let todo = newItem(type: .todo, typeData: .todo(ActionableData()), title: "todo", scheduledOn: day)
    let event = newItem(type: .calendar, typeData: .calendar(CalendarData()),
                        source: "gcal", externalID: "e", scheduledOn: day)
    let done = newItem(type: .todo, typeData: .todo(ActionableData()), title: "done", scheduledOn: day)
    let boxed = newItem(type: .todo, typeData: .todo(ActionableData()), title: "boxed", scheduledOn: day)
    for i in [todo, event, done, boxed] { try store.create(i) }
    try store.completeActionable(id: done.id)     // resolved; day preserved (15th)
    try store.setIceboxed(id: boxed.id, true)     // iceboxed; hidden from the schedule

    let ids = Set(try store.fetchActive(type: nil, from: day, to: day).map { $0.id })
    return ids == Set([todo.id, event.id, done.id])   // boxed excluded; done kept
}

// 41b. ScheduleAgenda.days routes actionables like the Today sidebar: an OPEN
//      item that's unscheduled or overdue rolls onto today; a future open item
//      keeps its day; a resolved overdue item anchors to its (out-of-window)
//      scheduled day and never leaks onto today. Guards the bug where
//      Today-surface items were missing from the schedule's today column.
check("ScheduleAgenda.days: unscheduled/overdue open actionables surface on today") {
    let today = CivilDate(year: 2026, month: 6, day: 13)
    func day(_ d: Int) -> CivilDate { CivilDate(year: 2026, month: 6, day: d) }
    let overdue = newItem(type: .todo, typeData: .todo(ActionableData()),
                          title: "overdue", scheduledOn: day(10))
    let unscheduled = newItem(type: .explore, typeData: .explore(ActionableData()),
                              title: "unscheduled", scheduledOn: nil)
    let future = newItem(type: .todo, typeData: .todo(ActionableData()),
                         title: "future", scheduledOn: day(20))
    let resolvedOverdue = newItem(type: .todo, typeData: .todo(ActionableData()),
                                  title: "resolvedOverdue", scheduledOn: day(10),
                                  resolvedAt: Date())
    let days = ScheduleAgenda.days(
        items: [overdue, unscheduled, future, resolvedOverdue],
        from: today, today: today)
    func titles(on d: CivilDate) -> Set<String> {
        Set(days.first(where: { $0.date == d })?.actionableGroups
            .flatMap(\.items).map(\.title) ?? [])
    }
    let onToday = titles(on: today) == Set(["overdue", "unscheduled"])
    let onFuture = titles(on: day(20)) == Set(["future"])
    // resolvedOverdue buckets to day(10) — before `from`/today, so outside the
    // rendered window: it must not appear, least of all on today.
    let resolvedHidden = !titles(on: today).contains("resolvedOverdue")
    return onToday && onFuture && resolvedHidden
}

// 42. CapturedItem.make: a bare capture lands unscheduled on Today; a dated
//     capture carries its day; calendar/blank are rejected.
check("CapturedItem.make: manual disposition + validation") {
    let (store, _) = try makeStore()
    let today = CivilDate(year: 2026, month: 6, day: 12)
    guard let bare = CapturedItem.make(
        kind: "todo", title: "laundry", body: nil,
        scheduledOnISO: nil, externalURL: nil, workspaceID: "local") else { return false }
    guard let dated = CapturedItem.make(
        kind: "reminder", title: "call mom", body: "## note",
        scheduledOnISO: "2026-06-20", externalURL: nil, workspaceID: "local") else { return false }
    let badKind = CapturedItem.make(
        kind: "calendar", title: "x", body: nil,
        scheduledOnISO: nil, externalURL: nil, workspaceID: "local")
    let blankTitle = CapturedItem.make(
        kind: "todo", title: "   ", body: nil,
        scheduledOnISO: nil, externalURL: nil, workspaceID: "local")
    guard badKind == nil, blankTitle == nil else { return false }

    try store.create(bare)
    try store.create(dated)
    let onToday = try store.fetchActionable(asOf: today).contains { $0.id == bare.id }
    return bare.source == "manual" && bare.externalID == nil
        && bare.scheduledOn == nil && bare.iceboxedAt == nil && onToday
        && dated.scheduledOn == CivilDate(year: 2026, month: 6, day: 20)
        && dated.type == "reminder"
}

// 43. CapturedItem.make(icebox: true) stamps iceboxedAt → lands in the Icebox,
//     not on Today.
check("CapturedItem.make: icebox flag routes to the Icebox") {
    let (store, _) = try makeStore()
    let today = CivilDate(year: 2026, month: 6, day: 12)
    guard let boxed = CapturedItem.make(
        kind: "todo", title: "later task", body: nil,
        scheduledOnISO: nil, externalURL: nil, icebox: true,
        workspaceID: "local") else { return false }
    try store.create(boxed)
    let onToday = try store.fetchActionable(asOf: today).contains { $0.id == boxed.id }
    let inIcebox = try store.fetchIceboxed().contains { $0.id == boxed.id }
    return boxed.iceboxedAt != nil && !onToday && inIcebox
}

// 43c. CapturedItem.make(listName:) threads the list onto the actionable
//      payload, round-trips through the store, and surfaces in knownListNames —
//      the same names the list_names read command returns.
check("CapturedItem.make: listName threads onto the actionable + round-trips") {
    let (store, _) = try makeStore()
    guard let item = CapturedItem.make(
        kind: "todo", title: "buy milk", body: nil,
        scheduledOnISO: nil, externalURL: nil, listName: "Errands",
        workspaceID: "local") else { return false }
    guard case .todo(let d) = item.typeData, d.listName == "Errands" else { return false }
    try store.create(item)
    guard let fetched = try store.fetch(id: item.id),
          case .todo(let fd) = fetched.typeData else { return false }
    let known = try store.knownListNames()
    return fd.listName == "Errands" && known.contains("Errands")
}

// 43d. clipboardMarkdown: a `---`-fenced block — heading, present-only metadata,
//      then body; omits status/source/ids.
check("clipboardMarkdown: fenced block + present-only metadata + body") {
    let data = ActionableData(listName: "Dev", externalURL: "https://x.test/1")
    let item = newItem(
        type: .explore, typeData: .explore(data),
        title: "Eval v4", scheduledOn: CivilDate(year: 2026, month: 6, day: 20),
        body: "Check the upgrade guide.")
    let md = item.clipboardMarkdown()
    return md.hasPrefix("---\n# Eval v4") && md.hasSuffix("---")
        && md.contains("- Kind: Explore")
        && md.contains("- List: Dev")
        && md.contains("- Scheduled: 2026-06-20")
        && md.contains("- Link: https://x.test/1")
        && md.contains("Check the upgrade guide.")
        && !md.contains("source") && !md.contains("resolved")
}

// 43e. A bare item → fence + heading + Kind only (no list/schedule/link/body).
check("clipboardMarkdown: bare item is fence + heading + kind") {
    let item = newItem(type: .todo, typeData: .todo(ActionableData()), title: "ping bob")
    let md = item.clipboardMarkdown()
    return md.hasPrefix("---\n# ping bob") && md.hasSuffix("---")
        && md.contains("- Kind: To-do")
        && !md.contains("- List:") && !md.contains("- Scheduled:") && !md.contains("- Link:")
}

// 43e2. A calendar item carries its meeting link in the metadata line.
check("clipboardMarkdown: calendar item includes its meeting link") {
    let item = newItem(
        type: .calendar,
        typeData: .calendar(CalendarData(externalURL: "https://meet.test/xyz")),
        title: "Standup")
    let md = item.clipboardMarkdown()
    return md.contains("- Kind: Calendar") && md.contains("- Link: https://meet.test/xyz")
}

// 43f. Batch framing: each item keeps its own fences, joined by a blank line.
check("ItemClipboard.serialize: each item self-fenced, joined by blank line") {
    let a = newItem(type: .todo, typeData: .todo(ActionableData()), title: "one")
    let b = newItem(type: .reminder, typeData: .reminder(ActionableData()), title: "two")
    let out = ItemClipboard.serialize([a, b])
    return out.components(separatedBy: "# one").count == 2
        && out.components(separatedBy: "# two").count == 2
        && out.contains("---\n\n---")
        && out.hasPrefix("---") && out.hasSuffix("---")
}

// 44. iceboxSummary: counts the iceboxed set by kind with aging; excludes
//     resolved / deleted / non-iceboxed.
check("iceboxSummary: counts by kind + aging") {
    let (store, _) = try makeStore()
    let today = CivilDate.today
    func ago(_ days: Int) -> Date { Date().addingTimeInterval(-Double(days) * 86_400) }
    let t1 = newItem(type: .todo, typeData: .todo(ActionableData()), iceboxedAt: ago(5))
    let t2 = newItem(type: .todo, typeData: .todo(ActionableData()), iceboxedAt: ago(40))
    let r1 = newItem(type: .reminder, typeData: .reminder(ActionableData()), iceboxedAt: ago(2))
    let e1 = newItem(type: .explore, typeData: .explore(ActionableData()), iceboxedAt: ago(50))
    let active = newItem(type: .todo, typeData: .todo(ActionableData()))   // not iceboxed
    let doneBoxed = newItem(type: .todo, typeData: .todo(ActionableData()),
                            iceboxedAt: ago(10), resolvedAt: Date())       // resolved → excluded
    for i in [t1, t2, r1, e1, active, doneBoxed] { try store.create(i) }
    let s = try store.iceboxSummary(asOf: today)
    return s.total == 4
        && s.byKind["todo"] == 2 && s.byKind["reminder"] == 1 && s.byKind["explore"] == 1
        && s.olderThan30 == 2                          // t2 (40d) + e1 (50d)
        && (s.oldestAgeDays ?? 0) >= 49                // oldest ≈ 50d
}

// 45. BriefingSnapshot.current: the today list (unscheduled + today-scheduled,
//     calendar dropped, iceboxed excluded), the lookahead window, and the
//     icebox summary.
check("BriefingSnapshot.current: today / upcoming / icebox slices") {
    let (store, _) = try makeStore()
    let today = CivilDate.today
    let todo = newItem(type: .todo, typeData: .todo(ActionableData()), title: "do it")
    let rem = newItem(type: .reminder, typeData: .reminder(ActionableData()),
                      title: "nudge", scheduledOn: today)
    let soon = newItem(type: .explore, typeData: .explore(ActionableData()),
                       title: "later", scheduledOn: today.adding(days: 3))
    let far = newItem(type: .todo, typeData: .todo(ActionableData()),
                      title: "far", scheduledOn: today.adding(days: 60))
    let cal = newItem(type: .calendar, typeData: .calendar(CalendarData()),
                      source: "gcal", externalID: "e1", scheduledOn: today)
    let boxed = newItem(type: .todo, typeData: .todo(ActionableData()), iceboxedAt: Date())
    for i in [todo, rem, soon, far, cal, boxed] { try store.create(i) }

    let snap = try BriefingSnapshot.current(store: store, asOf: today)
    let upcomingTitles = snap.upcoming.map { $0.title }
    return snap.today.contains { $0.id == todo.id }        // unscheduled accumulates
        && snap.today.contains { $0.id == rem.id }         // today-scheduled reminder
        && !snap.today.contains { $0.kind == "calendar" }  // calendar dropped
        && !snap.today.contains { $0.id == boxed.id }      // iceboxed excluded
        && upcomingTitles.contains("later")                // in-window future
        && !upcomingTitles.contains("far")                 // beyond the window
        && snap.icebox.total == 1                          // the one boxed todo
}

// 45b. The briefing surfaces each row's manual list position (drag-reorder
//      rank) so the persona can factor it into prioritization; unranked → nil.
check("BriefingSnapshot: rows carry the manual list position") {
    let (store, _) = try makeStore()
    let today = CivilDate.today
    var top = newItem(type: .todo, typeData: .todo(ActionableData(listName: "Work")),
                      title: "top", scheduledOn: today)
    top.position = 0
    var low = newItem(type: .todo, typeData: .todo(ActionableData(listName: "Work")),
                      title: "low", scheduledOn: today)
    low.position = 1024
    let unranked = newItem(type: .todo, typeData: .todo(ActionableData()), title: "unranked")
    for i in [top, low, unranked] { try store.create(i) }

    let rows = try BriefingSnapshot.current(store: store, asOf: today).today
    func position(_ id: String) -> Double? { rows.first { $0.id == id }?.position ?? nil }
    return position(top.id) == 0
        && position(low.id) == 1024
        && rows.first { $0.id == unranked.id }?.position == nil
}

// SessionReconciler: resume of the tracked agent gates the post-resume reflow.
check("SessionReconciler: resume matching spawned id → reflow, no adopt") {
    let d = SessionReconciler.decide(
        source: "resume", reportedId: "A", spawnedId: "A", awaitingResumeReady: true)
    return d.reflow && d.adoptId == nil && !d.ignored
}

// SessionReconciler: a sidecar's startup (foreign id) is ignored — never stomps.
check("SessionReconciler: startup with foreign id → ignored") {
    let d = SessionReconciler.decide(
        source: "startup", reportedId: "SIDECAR", spawnedId: "A", awaitingResumeReady: true)
    return d.ignored && d.adoptId == nil && !d.reflow
}

// SessionReconciler: /clear adopts the new id (and never reflows mid-session).
check("SessionReconciler: clear adopts the new id") {
    let d = SessionReconciler.decide(
        source: "clear", reportedId: "B", spawnedId: "A", awaitingResumeReady: false)
    return d.adoptId == "B" && !d.reflow && !d.ignored
}

// SessionReconciler: /compact with the same id → no adopt, no reflow.
check("SessionReconciler: compact with same id → no adopt") {
    let d = SessionReconciler.decide(
        source: "compact", reportedId: "A", spawnedId: "A", awaitingResumeReady: false)
    return d.adoptId == nil && !d.reflow && !d.ignored
}

// SessionReconciler: an unknown source is ignored.
check("SessionReconciler: unknown source ignored") {
    SessionReconciler.decide(
        source: "weird", reportedId: "A", spawnedId: "A", awaitingResumeReady: false).ignored
}

// ActionableListSort: sort by text, ignoring a leading emoji (the reported bug).
check("ActionableListSort: emoji-prefixed AA sorts before star-prefixed Galaxy") {
    ActionableListSort.less("🐜 AA", "★ Galaxy")
        && !ActionableListSort.less("★ Galaxy", "🐜 AA")
}

// ActionableListSort: plain text names sort normally.
check("ActionableListSort: no-emoji names sort by text") {
    ActionableListSort.less("AA", "Galaxy")
}

// ActionableListSort: a non-emoji symbol prefix (★ = U+2605, So) is ignored too.
check("ActionableListSort: symbol prefix is stripped to its text") {
    ActionableListSort.key(for: "★ Galaxy").text == "Galaxy"
        && ActionableListSort.key(for: "🐜 AA").text == "AA"
}

// ActionableListSort: interior emoji are ignored, not just leading ones.
check("ActionableListSort: interior emoji ignored") {
    ActionableListSort.key(for: "Launch 🚀").text == "Launch"
}

// ActionableListSort: glyph-only names are flagged and sort AFTER text names.
check("ActionableListSort: glyph-only sorts after text") {
    let k = ActionableListSort.key(for: "🔥")
    return k.glyphOnly && ActionableListSort.less("Galaxy", "🔥")
        && !ActionableListSort.less("🔥", "Galaxy")
}

// ActionableListSort: same text + different glyph → deterministic, stable order.
check("ActionableListSort: same text tiebreaks on the original name") {
    let a = ActionableListSort.less("🐜 AA", "★ AA")
    let b = ActionableListSort.less("★ AA", "🐜 AA")
    return a != b
}

// ActionableListSort: full ordering of a mixed set (text first, glyph-only last).
check("ActionableListSort: mixed set orders text first, glyph-only last") {
    let sorted = ["★ Galaxy", "🐜 AA", "Zebra", "🔥"]
        .sorted(by: ActionableListSort.less)
    return sorted == ["🐜 AA", "★ Galaxy", "Zebra", "🔥"]
}

// ActionableListSort: digits/letters in the name are kept (not stripped).
check("ActionableListSort: digits are kept in the key") {
    ActionableListSort.key(for: "1Password").text == "1Password"
}

// ItemLinks: collect valid externalURLs, dedupe, drop missing/invalid.
check("ItemLinks: collects valid links, dedupes, drops missing/invalid") {
    let a = newItem(type: .explore, typeData: .explore(ActionableData(externalURL: "https://a.test/x")))
    let dup = newItem(type: .todo, typeData: .todo(ActionableData(externalURL: "https://a.test/x")))
    let b = newItem(type: .todo, typeData: .todo(ActionableData(externalURL: "https://b.test/y")))
    let cal = newItem(type: .calendar, typeData: .calendar(CalendarData(externalURL: "https://c.test/z")))
    let none = newItem(type: .todo, typeData: .todo(ActionableData()))
    let blank = newItem(type: .todo, typeData: .todo(ActionableData(externalURL: "   ")))
    let urls = ItemLinks.urls(for: [a, dup, b, cal, none, blank])
    return urls.map(\.absoluteString) == ["https://a.test/x", "https://b.test/y", "https://c.test/z"]
}

// ItemLinks: empty for a link-less set (drives the disabled glyph).
check("ItemLinks: empty for a link-less set") {
    let x = newItem(type: .todo, typeData: .todo(ActionableData()))
    return ItemLinks.urls(for: [x]).isEmpty
}

// undelete clears the tombstone; the row returns to the active set.
check("undelete: clears deletedAt, returns to active") {
    let (store, _) = try makeStore()
    let item = newItem(type: .todo, typeData: .todo(ActionableData()), title: "back")
    try store.create(item)
    try store.softDelete(id: item.id)
    guard try store.fetch(id: item.id)?.deletedAt != nil else { return false }
    try store.undelete(id: item.id)
    guard let after = try store.fetch(id: item.id) else { return false }
    let active = try store.fetchActive(type: .todo).contains { $0.id == item.id }
    return after.deletedAt == nil && active
}

// fetchTrashed: soft-deleted actionables only, newest-deleted first; excludes
// active rows and calendar; includes iceboxed/resolved deletions.
check("fetchTrashed: deleted actionables only, newest first") {
    let (store, _) = try makeStore()
    let active = newItem(type: .todo, typeData: .todo(ActionableData()), title: "active")
    let a = newItem(type: .todo, typeData: .todo(ActionableData()), title: "a")
    let b = newItem(type: .reminder, typeData: .reminder(ActionableData()), title: "b")
    let cal = newItem(type: .calendar, typeData: .calendar(CalendarData()),
                      source: "gcal", externalID: "c")
    for i in [active, a, b, cal] { try store.create(i) }
    try store.softDelete(id: a.id)
    Thread.sleep(forTimeInterval: 0.005)   // ensure b's deleted_at sorts strictly newer
    try store.softDelete(id: b.id)
    try store.softDelete(id: cal.id)       // calendar deletion must NOT appear
    let ids = try store.fetchTrashed().map { $0.id }
    return ids == [b.id, a.id]
}

// ItemActionState.allSynced: true only when every item carries an externalID.
check("ItemActionState: allSynced across a set") {
    let synced = newItem(type: .todo, typeData: .todo(ActionableData()),
                         source: "linear", externalID: "FLEX-1")
    let local = newItem(type: .todo, typeData: .todo(ActionableData()))
    return ItemActionState([synced]).allSynced
        && !ItemActionState([synced, local]).allSynced
        && !ItemActionState([local]).allSynced
}

// ItemActionState.allDeleted: true only when every item is soft-deleted.
check("ItemActionState: allDeleted across a set") {
    var del = newItem(type: .todo, typeData: .todo(ActionableData()))
    del.deletedAt = Date()
    let active = newItem(type: .todo, typeData: .todo(ActionableData()))
    return ItemActionState([del]).allDeleted
        && !ItemActionState([del, active]).allDeleted
        && !ItemActionState([active]).allDeleted
}

// setExternalURL sets + clears an actionable's URL, preserving kind + list name;
// a non-actionable (calendar) item is left untouched.
check("setExternalURL: sets, clears, preserves kind + list; calendar untouched") {
    let (store, _) = try makeStore()
    let item = newItem(type: .todo,
                       typeData: .todo(ActionableData(listName: "Errands")))
    try store.create(item)
    try store.setExternalURL(id: item.id, to: "https://example.com/x")
    guard let set = try store.fetch(id: item.id),
          case .todo(let d) = set.typeData else { return false }
    try store.setExternalURL(id: item.id, to: "   ")   // blank → cleared
    guard let cleared = try store.fetch(id: item.id),
          case .todo(let d2) = cleared.typeData else { return false }

    let cal = newItem(type: .calendar,
                      typeData: .calendar(CalendarData(externalURL: "https://meet.test/z")),
                      source: "gcal", externalID: "evt-x")
    try store.create(cal)
    try store.setExternalURL(id: cal.id, to: "https://nope.test")
    guard let calAfter = try store.fetch(id: cal.id),
          case .calendar(let cd) = calAfter.typeData else { return false }

    return d.externalURL == "https://example.com/x" && d.listName == "Errands"
        && d2.externalURL == nil && d2.listName == "Errands"
        && cd.externalURL == "https://meet.test/z"   // calendar URL untouched
}

// fetchAllActionable returns every non-deleted todo/reminder/explore (incl.
// iceboxed + resolved), excluding soft-deleted and calendar rows — the
// `list --state active` source.
check("fetchAllActionable: all non-deleted actionables, excl. deleted + calendar") {
    let (store, _) = try makeStore()
    let open = newItem(type: .todo, typeData: .todo(ActionableData()), title: "open")
    let iceboxed = newItem(type: .reminder, typeData: .reminder(ActionableData()),
                           title: "iceboxed", iceboxedAt: Date())
    let resolved = newItem(type: .explore, typeData: .explore(ActionableData()),
                           title: "resolved", resolvedAt: Date())
    let deleted = newItem(type: .todo, typeData: .todo(ActionableData()), title: "deleted")
    let cal = newItem(type: .calendar, typeData: .calendar(CalendarData()),
                      source: "gcal", externalID: "evt-1", title: "cal")
    for i in [open, iceboxed, resolved, deleted, cal] { try store.create(i) }
    try store.softDelete(id: deleted.id)
    let ids = Set(try store.fetchAllActionable().map { $0.id })
    return ids == Set([open.id, iceboxed.id, resolved.id])
}

// MARK: - Task system (tasks + task_runs)

/// A fresh in-memory tasks store, migrated through the real migrator.
func makeTasksStore() throws -> (TasksStore, DatabaseQueue) {
    let queue = try DatabaseQueue()  // in-memory
    try ItemsDatabase.migrator.migrate(queue)
    return (TasksStore(dbQueue: queue), queue)
}

func newTask(
    name: String = "t",
    triggerType: String = "recurring",
    cadenceKind: String? = "interval",
    intervalSeconds: Int? = 900,
    dailyTime: String? = nil,
    weekdays: String? = nil,
    windowStart: String? = nil,
    windowEnd: String? = nil,
    runAt: Date? = nil,
    todayKey: String? = nil,
    prompt: String = "do the thing",
    enabled: Bool = true,
    lastRunAt: Date? = nil,
    position: Double? = nil,
    createdAt: Date = Date()   // control creation time for first-fire tests
) -> AgentTask {
    AgentTask(
        id: UUIDv7.generate(), name: name, triggerType: triggerType,
        cadenceKind: cadenceKind, intervalSeconds: intervalSeconds,
        dailyTime: dailyTime, weekdays: weekdays, windowStart: windowStart,
        windowEnd: windowEnd, runAt: runAt, todayKey: todayKey,
        prompt: prompt, enabled: enabled, lastRunAt: lastRunAt,
        position: position, createdAt: createdAt, updatedAt: createdAt)
}

func newRun(
    taskID: String? = nil, taskName: String = "t", trigger: String = "manual",
    firedAt: Date = Date(), status: String = "sent", detail: String? = nil,
    prompt: String? = nil
) -> TaskRun {
    TaskRun(
        id: UUIDv7.generate(), taskID: taskID, taskName: taskName,
        trigger: trigger, firedAt: firedAt, status: status, detail: detail,
        prompt: prompt)
}

// T1. A fresh in-memory DB migrated through the real migrator seeds the two
//     built-in Today sync triggers plus the disabled Spend capture and Priority
//     capture tasks; the run log starts empty.
check("tasks: migration seeds the built-in tasks") {
    let (store, _) = try makeTasksStore()
    let all = try store.allTasks()
    guard let cal = all.first(where: { $0.todayKey == "calendar_refresh" }),
          let todo = all.first(where: { $0.todayKey == "todo_refresh" }),
          let spend = all.first(where: { $0.name == "Spend capture" }),
          let priority = all.first(where: { $0.name == "Priority capture" })
    else { return false }
    return try all.count == 4
        && cal.triggerType == "today" && cal.enabled && cal.prompt == "Sync my calendar"
        && todo.triggerType == "today" && todo.enabled
        && todo.prompt == "Sync my Linear issues"
        && spend.triggerType == "recurring" && spend.cadenceKind == "interval"
        && spend.intervalSeconds == 7200 && !spend.enabled
        && spend.windowStart == "07:05" && spend.windowEnd == "19:05"
        && priority.triggerType == "recurring" && priority.cadenceKind == "interval"
        && priority.intervalSeconds == 7200 && !priority.enabled
        && priority.windowStart == "07:15" && priority.windowEnd == "19:15"
        && store.recentRuns().isEmpty
}

// T2. Every trigger type round-trips through the store, preserving its cadence
//     fields (interval vs daily), the one-shot fire instant, and the manual key.
check("tasks: round-trip every trigger type + cadence fields") {
    let (store, _) = try makeTasksStore()
    let interval = newTask(name: "sync", triggerType: "recurring",
                           cadenceKind: "interval", intervalSeconds: 900)
    let daily = newTask(name: "briefing", triggerType: "recurring",
                        cadenceKind: "daily", intervalSeconds: nil, dailyTime: "07:00")
    let oneShot = newTask(name: "ping", triggerType: "one_shot",
                          cadenceKind: nil, intervalSeconds: nil,
                          runAt: Date(timeIntervalSince1970: 1_800_000_000))
    let today = newTask(name: "refresh", triggerType: "today",
                        cadenceKind: nil, intervalSeconds: nil,
                        todayKey: "calendar_refresh")
    for t in [interval, daily, oneShot, today] { try store.create(t) }
    // Two built-in tasks are seeded by the migration, so assert membership of
    // the four created here rather than an exact total.
    guard let i = try store.task(id: interval.id),
          let d = try store.task(id: daily.id),
          let o = try store.task(id: oneShot.id),
          let m = try store.task(id: today.id) else { return false }
    return i.cadenceKind == "interval" && i.intervalSeconds == 900
        && d.cadenceKind == "daily" && d.dailyTime == "07:00" && d.intervalSeconds == nil
        && o.triggerType == "one_shot" && o.runAt == oneShot.runAt
        && m.triggerType == "today" && m.todayKey == "calendar_refresh"
}

// T3. The write surface Phase 5 drives: update replaces fields in place, and
//     setEnabled flips the flag.
check("tasks: update + setEnabled write through") {
    let (store, _) = try makeTasksStore()
    var t = newTask(name: "v1", intervalSeconds: 900, enabled: true)
    try store.create(t)
    t.name = "v2"
    t.intervalSeconds = 3600
    try store.update(t)
    try store.setEnabled(id: t.id, false)
    guard let after = try store.task(id: t.id) else { return false }
    return after.name == "v2" && after.intervalSeconds == 3600 && !after.enabled
}

// T4. delete removes the task row entirely (the seeded built-ins remain).
check("tasks: delete removes the row") {
    let (store, _) = try makeTasksStore()
    let t = newTask(todayKey: "custom_delete")
    try store.create(t)
    try store.delete(id: t.id)
    return (try store.task(id: t.id)) == nil
}

// T5. markRan stamps last_run_at — the field the recurring due-eval reads.
check("tasks: markRan stamps last_run_at") {
    let (store, _) = try makeTasksStore()
    let t = newTask(lastRunAt: nil)
    try store.create(t)
    let when = Date(timeIntervalSince1970: 1_700_000_000)
    try store.markRan(id: t.id, at: when)
    return try store.task(id: t.id)?.lastRunAt == when
}

// T6. The run log: recordRun inserts, recentRuns returns reverse-chronological
//     by fired_at, and the detail snapshot round-trips.
check("task_runs: recordRun + recentRuns newest-first") {
    let (store, _) = try makeTasksStore()
    func at(_ t: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(t)) }
    let old = newRun(taskName: "old", trigger: "recurring", firedAt: at(100))
    let mid = newRun(taskName: "mid", trigger: "manual", firedAt: at(200),
                     status: "skipped", detail: "agent not running")
    let new = newRun(taskName: "new", trigger: "run_now", firedAt: at(300),
                     prompt: "summarize today")
    for r in [old, mid, new] { try store.recordRun(r) }
    let runs = try store.recentRuns(limit: 10)
    let names = runs.map { $0.taskName }
    let midDetail = runs.first { $0.taskName == "mid" }?.detail
    return names == ["new", "mid", "old"]
        && midDetail == "agent not running"
        && runs.first?.status == "sent"
        && runs.first?.prompt == "summarize today"   // snapshot column round-trips
}

// T7. TaskRun.make encodes the Tier-0 outcome: sent + nil detail when the agent
//     is running, skipped + a reason when it isn't.
check("task_runs: make() encodes sent vs skipped") {
    let sent = TaskRun.make(taskID: "t1", name: "X", trigger: "run_now",
                            agentRunning: true, prompt: "do X")
    let skipped = TaskRun.make(taskID: nil, name: "Y", trigger: "manual", agentRunning: false)
    return sent.status == "sent" && sent.detail == nil && sent.taskID == "t1"
        && sent.prompt == "do X"
        && skipped.status == "skipped" && skipped.detail == "agent not running"
        && skipped.taskID == nil && skipped.prompt == nil
}

// T8. tasks(todayKey:) returns every task bound to a glyph key (the set the
//     glyph fires), and is empty for an unknown key.
check("tasks: tasks(todayKey:) returns all matching, empty for unknown") {
    let (store, _) = try makeTasksStore()
    // A second calendar-keyed Today task alongside the seeded one.
    try store.create(newTask(name: "Calendar extras", triggerType: "today",
                             cadenceKind: nil, intervalSeconds: nil,
                             todayKey: "calendar_refresh"))
    let cal = try store.tasks(todayKey: "calendar_refresh")
    return try cal.count == 2
        && cal.allSatisfy { $0.triggerType == "today" }
        && cal.contains { $0.name == "Calendar sync" }
        && store.tasks(todayKey: "nope").isEmpty
}

// T9. The cadence-precision migration adds the columns and a windowed-interval
//     task (weekdays + window_start/window_end) round-trips through the store.
check("tasks: weekdays + window round-trip through the store") {
    let (store, _) = try makeTasksStore()
    let windowed = newTask(
        name: "Progress check", triggerType: "recurring",
        cadenceKind: "interval", intervalSeconds: 3600,
        weekdays: "1,2,3,4,5", windowStart: "08:55", windowEnd: "16:55")
    try store.create(windowed)
    guard let w = try store.task(id: windowed.id) else { return false }
    return w.weekdays == "1,2,3,4,5"
        && w.windowStart == "08:55" && w.windowEnd == "16:55"
        && w.intervalSeconds == 3600
}

// T10. weekdaySet parses the mask; a nil, empty, or all-out-of-range mask
//      resolves to the full week, and out-of-range entries are dropped.
check("tasks: weekdaySet parses the mask, unset = every day") {
    let weekdays = newTask(weekdays: "1,2,3,4,5").weekdaySet
    let single = newTask(weekdays: "2,4").weekdaySet
    let unset = newTask(weekdays: nil).weekdaySet
    let empty = newTask(weekdays: "").weekdaySet
    let junk = newTask(weekdays: "0,9, 3 ").weekdaySet   // drops 0/9, keeps 3
    return weekdays == Set([1, 2, 3, 4, 5])
        && single == Set([2, 4])
        && unset == Set(1...7)
        && empty == Set(1...7)
        && junk == Set([3])
}

// T11. allTasks() orders by position (nulls last): a ranked task sorts ahead of
//      unranked rows, which fall back to creation order.
check("tasks: allTasks orders by position, nulls last") {
    let (store, _) = try makeTasksStore()
    var ranked = newTask(name: "ranked")
    ranked.position = 10
    let unranked = newTask(name: "unranked")   // nil position
    try store.create(unranked)   // created first…
    try store.create(ranked)     // …but ranked sorts ahead via position
    let names = try store.allTasks().map { $0.name }
    guard let ri = names.firstIndex(of: "ranked"),
          let ui = names.firstIndex(of: "unranked") else { return false }
    return ri < ui
}

// T12. TaskReorder: the renormalize path (an all-unranked list) then a single
//      midpoint write both yield the dropped order. Works off the store's
//      actual initial order (x, y, z) rather than assuming creation order — for
//      three rows minted in one millisecond the created_at ties break on the
//      UUIDv7 id, which isn't guaranteed monotonic.
check("tasks: TaskReorder places and renormalizes") {
    let (store, _) = try makeTasksStore()
    // Clear the seeded built-ins so the list is exactly our three.
    for t in try store.allTasks() { try store.delete(id: t.id) }
    for t in [newTask(name: "a"), newTask(name: "b"), newTask(name: "c")] {
        try store.create(t)
    }

    let ids0 = try store.allTasks().map { $0.id }
    guard ids0.count == 3 else { return false }
    let (x, y, z) = (ids0[0], ids0[1], ids0[2])

    // Renormalize path: move the last row between the first two → [x, z, y].
    let dest1 = try store.allTasks().filter { $0.id != z }
    TaskReorder.apply(store: store, destination: dest1, movedID: z, insertAt: 1)
    let order1 = try store.allTasks().map { $0.id }

    // Single-write path: move the first row to the end → [z, y, x].
    let dest2 = try store.allTasks().filter { $0.id != x }
    TaskReorder.apply(store: store, destination: dest2, movedID: x, insertAt: dest2.count)
    let order2 = try store.allTasks().map { $0.id }

    return order1 == [x, z, y] && order2 == [z, y, x]
}

// T13. pruneRuns trims the run log to the most recent N, deleting the oldest.
check("task_runs: pruneRuns keeps the most recent N") {
    let (store, _) = try makeTasksStore()
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    for i in 0..<10 {
        try store.recordRun(newRun(
            taskName: "t\(i)", firedAt: base.addingTimeInterval(Double(i) * 60)))
    }
    try store.pruneRuns(keeping: 4)
    let remaining = try store.recentRuns(limit: 100)
    // The 4 newest (i = 9,8,7,6) survive, newest first.
    return remaining.count == 4
        && remaining.map { $0.taskName } == ["t9", "t8", "t7", "t6"]
}

// ── TaskSchedule (Phase 4 due-eval) ──────────────────────────────────────────
// Weekdays are derived from each test date via isoWeekday, so the cases hold on
// any calendar/timezone.
let hbCal = Calendar.current
func hbAt(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    hbCal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

// S1. one_shot: due at/after runAt; nil runAt fires on the next tick.
check("schedule: one_shot due at/after runAt; nil = next tick") {
    let fire = hbAt(2026, 6, 16, 9, 0)
    let t = newTask(triggerType: "one_shot", cadenceKind: nil, intervalSeconds: nil, runAt: fire)
    let nilRun = newTask(triggerType: "one_shot", cadenceKind: nil, intervalSeconds: nil, runAt: nil)
    return !TaskSchedule.isDue(t, now: hbAt(2026, 6, 16, 8, 59))
        && TaskSchedule.isDue(t, now: fire)
        && TaskSchedule.isDue(t, now: hbAt(2026, 6, 16, 9, 1))
        && TaskSchedule.isDue(nilRun, now: hbAt(2026, 6, 16, 0, 0))
}

// S2. daily: fires at/after the slot once per day; deduped by lastRunAt.
check("schedule: daily fires after its slot, deduped by lastRunAt") {
    let created = hbAt(2026, 6, 15, 0, 0)
    let day = hbAt(2026, 6, 16, 9, 0)
    let wd = TaskSchedule.isoWeekday(of: day, hbCal)
    let t = newTask(triggerType: "recurring", cadenceKind: "daily", intervalSeconds: nil,
                    dailyTime: "08:55", weekdays: "\(wd)", createdAt: created)
    var ran = t; ran.lastRunAt = hbAt(2026, 6, 16, 8, 55)
    return !TaskSchedule.isDue(t, now: hbAt(2026, 6, 16, 8, 54))  // before slot
        && TaskSchedule.isDue(t, now: day)                       // after slot, never ran
        && !TaskSchedule.isDue(ran, now: day)                    // already ran today
}

// S3. daily: a task created after today's slot waits for the next occurrence.
check("schedule: daily created after the slot does not back-fire same day") {
    let created = hbAt(2026, 6, 16, 9, 0)   // after 08:55
    let t = newTask(triggerType: "recurring", cadenceKind: "daily", intervalSeconds: nil,
                    dailyTime: "08:55", createdAt: created)
    return !TaskSchedule.isDue(t, now: hbAt(2026, 6, 16, 9, 30))
}

// S4. daily: weekday mask excludes the slot's day.
check("schedule: daily skips a slot on a disallowed weekday") {
    let day = hbAt(2026, 6, 16, 9, 0)
    let wd = TaskSchedule.isoWeekday(of: day, hbCal)
    let other = wd == 7 ? 1 : wd + 1
    let t = newTask(triggerType: "recurring", cadenceKind: "daily", intervalSeconds: nil,
                    dailyTime: "08:55", weekdays: "\(other)", createdAt: hbAt(2026, 6, 15, 0, 0))
    return !TaskSchedule.isDue(t, now: day)
}

// S5. continuous interval: first fire anchors to createdAt + interval (3A).
check("schedule: continuous interval first fire = createdAt + interval") {
    let created = hbAt(2026, 6, 16, 10, 3)
    let t = newTask(triggerType: "recurring", cadenceKind: "interval",
                    intervalSeconds: 900, createdAt: created)   // 15 min
    return !TaskSchedule.isDue(t, now: hbAt(2026, 6, 16, 10, 17))  // 14 min in
        && TaskSchedule.isDue(t, now: hbAt(2026, 6, 16, 10, 18))   // 15 min in
}

// S6. continuous interval: a long gap coalesces to a single fire, spaced from
//     lastRunAt (runs once, not once per missed interval).
check("schedule: continuous interval coalesces a long gap to one fire") {
    var t = newTask(triggerType: "recurring", cadenceKind: "interval", intervalSeconds: 900)
    t.lastRunAt = hbAt(2026, 6, 16, 7, 0)
    var stamped = t; stamped.lastRunAt = hbAt(2026, 6, 16, 10, 0)
    return TaskSchedule.isDue(t, now: hbAt(2026, 6, 16, 10, 0))        // 3h later → due
        && !TaskSchedule.isDue(stamped, now: hbAt(2026, 6, 16, 10, 5)) // just stamped → not due
}

// S7. windowed interval: fires at an anchored slot inside the window; never
//     before the window opens or after it closes.
check("schedule: windowed interval fires only inside the window, on slots") {
    let created = hbAt(2026, 6, 16, 0, 0)
    let day = hbAt(2026, 6, 16, 9, 55)
    let wd = TaskSchedule.isoWeekday(of: day, hbCal)
    let t = newTask(triggerType: "recurring", cadenceKind: "interval", intervalSeconds: 3600,
                    weekdays: "\(wd)", windowStart: "08:55", windowEnd: "16:55",
                    createdAt: created)
    return !TaskSchedule.isDue(t, now: hbAt(2026, 6, 16, 8, 0))    // before window
        && TaskSchedule.isDue(t, now: hbAt(2026, 6, 16, 8, 55))    // open slot
        && TaskSchedule.isDue(t, now: day)                         // 09:55 slot
        && !TaskSchedule.isDue(t, now: hbAt(2026, 6, 16, 17, 30))  // after window
}

// S8. manual + today are never due on a tick.
check("schedule: manual and today never fire on a tick") {
    let m = newTask(triggerType: "manual", cadenceKind: nil, intervalSeconds: nil)
    let d = newTask(triggerType: "today", cadenceKind: nil, intervalSeconds: nil,
                    todayKey: "calendar_refresh")
    return !TaskSchedule.isDue(m, now: hbAt(2026, 6, 16, 9, 0))
        && !TaskSchedule.isDue(d, now: hbAt(2026, 6, 16, 9, 0))
}

// ── TaskSchedule.nextRun (row "next" chip) ───────────────────────────────────

// N1. daily (already current on its last slot): next is today's slot when
//     ahead, else the next day's. A task that hasn't run its due slot reads as
//     "due" instead — that path is N5; here we exercise the forward math.
check("nextRun: daily picks today's slot when ahead, else next day") {
    var ahead = newTask(triggerType: "recurring", cadenceKind: "daily", intervalSeconds: nil,
                        dailyTime: "08:55", createdAt: hbAt(2026, 6, 10, 0, 0))
    ahead.lastRunAt = hbAt(2026, 6, 15, 8, 55)        // ran yesterday → not overdue
    var ranToday = ahead
    ranToday.lastRunAt = hbAt(2026, 6, 16, 8, 55)     // already ran today
    return TaskSchedule.nextRun(ahead, after: hbAt(2026, 6, 16, 7, 0)) == hbAt(2026, 6, 16, 8, 55)
        && TaskSchedule.nextRun(ranToday, after: hbAt(2026, 6, 16, 9, 30)) == hbAt(2026, 6, 17, 8, 55)
}

// N2. daily weekday: skips disallowed days to the next allowed one.
check("nextRun: daily skips to the next allowed weekday") {
    let day = hbAt(2026, 6, 16, 7, 0)
    let wd = TaskSchedule.isoWeekday(of: day, hbCal)
    let plus2 = wd + 2 > 7 ? wd + 2 - 7 : wd + 2
    let t = newTask(triggerType: "recurring", cadenceKind: "daily", intervalSeconds: nil,
                    dailyTime: "08:55", weekdays: "\(plus2)", createdAt: hbAt(2026, 6, 10, 0, 0))
    guard let next = TaskSchedule.nextRun(t, after: day) else { return false }
    return TaskSchedule.isoWeekday(of: next, hbCal) == plus2 && next > day
}

// N3. continuous interval: next = lastRunAt + interval (future).
check("nextRun: continuous interval = lastRunAt + interval") {
    var t = newTask(triggerType: "recurring", cadenceKind: "interval", intervalSeconds: 900)
    t.lastRunAt = hbAt(2026, 6, 16, 10, 0)
    return TaskSchedule.nextRun(t, after: hbAt(2026, 6, 16, 10, 5)) == hbAt(2026, 6, 16, 10, 15)
}

// N4. windowed interval (last slot already ran): next slot inside the window;
//     past the close → next day's open.
check("nextRun: windowed interval next slot, then next day's open") {
    var t = newTask(triggerType: "recurring", cadenceKind: "interval", intervalSeconds: 3600,
                    windowStart: "08:55", windowEnd: "16:55", createdAt: hbAt(2026, 6, 1, 0, 0))
    t.lastRunAt = hbAt(2026, 6, 16, 8, 55)   // ran the 08:55 slot → not overdue
    let mid = TaskSchedule.nextRun(t, after: hbAt(2026, 6, 16, 9, 10))   // → 09:55
    let past = TaskSchedule.nextRun(t, after: hbAt(2026, 6, 16, 17, 30)) // → tomorrow 08:55
    return mid == hbAt(2026, 6, 16, 9, 55)
        && past == hbAt(2026, 6, 17, 8, 55)
}

// N5. a due task returns ≤ now (the chip reads "due").
check("nextRun: a due task is imminent (≤ now)") {
    var t = newTask(triggerType: "recurring", cadenceKind: "interval", intervalSeconds: 900)
    t.lastRunAt = hbAt(2026, 6, 16, 7, 0)   // 3h overdue
    let now = hbAt(2026, 6, 16, 10, 0)
    guard let next = TaskSchedule.nextRun(t, after: now) else { return false }
    return next <= now
}

// N6. no forward schedule: manual, today, and disabled return nil.
check("nextRun: manual / today / disabled have no next run") {
    let m = newTask(triggerType: "manual", cadenceKind: nil, intervalSeconds: nil)
    let d = newTask(triggerType: "today", cadenceKind: nil, intervalSeconds: nil,
                    todayKey: "calendar_refresh")
    let off = newTask(triggerType: "recurring", cadenceKind: "interval",
                      intervalSeconds: 900, enabled: false)
    let now = hbAt(2026, 6, 16, 10, 0)
    return TaskSchedule.nextRun(m, after: now) == nil
        && TaskSchedule.nextRun(d, after: now) == nil
        && TaskSchedule.nextRun(off, after: now) == nil
}

print(failures == 0
    ? "\n✅ all smoke checks passed"
    : "\n❌ \(failures) smoke check(s) failed")
exit(failures == 0 ? 0 : 1)
