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

/// `check` for a body that touches `@MainActor` state (the selection model).
///
/// This tool's top-level code is nonisolated but runs on the main thread, so
/// asserting the isolation is accurate rather than a workaround — it only has to
/// be stated, because the compiler can't infer it from top-level code. One
/// bridge here rather than a wrapper inside every such body.
func checkMainActor(_ name: String, _ body: @MainActor () throws -> Bool) {
    check(name) { try MainActor.assumeIsolated { try body() } }
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

// 22. Update refreshes title/body/url and preserves type, but resolution now
//     follows Linear: an issue that is not completed upstream is not resolved
//     here. This assertion is inverted from what it was — the old rule never
//     unresolved, which left a regressed issue permanently wrong AND permanently
//     immune to reconcile (resolved rows are spared). Verified against the live
//     workspace before flipping it: 17 of 18 resolved Linear rows were Done
//     upstream, so nothing depended on a local completion outsurviving a sync.
check("actionable sync: update refreshes content, preserves type, follows upstream resolution") {
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
        && after.resolvedAt == nil           // not completed upstream → unresolved
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
    let outcome = try store.applyActionableSync(
        rows: [], workspaceID: "local", source: "linear",
        keep: [], reconcile: true, allowEmptyKeep: false)
    guard let x = try fetchByExt(queue, "X-1") else { return false }
    return x.deletedAt == nil
        && outcome.reconcileWithheld && outcome.withheldReason == .emptyFetch
}

// MARK: - Full-turnover guard

// The 2026-08-03 mass-delete, reduced: an existing keyed set, an incoming set
// that overlaps it nowhere, and reconcile must NOT run. The pre-upsert sampling
// is what this pins — measured after the upsert loop, the two freshly created
// rows would be found in `keep` and the retirement would sail through, which is
// exactly how 31 items were lost while 33 were created.
check("actionable sync: full turnover withholds reconcile") {
    let (store, queue) = try makeStore()
    try store.applyActionableSync(
        rows: [lrow("OLD-1", "started"), lrow("OLD-2", "started")],
        workspaceID: "local", source: "linear",
        keep: ["OLD-1", "OLD-2"], reconcile: false, allowEmptyKeep: false)
    let outcome = try store.applyActionableSync(
        rows: [lrow("NEW-1", "started"), lrow("NEW-2", "started")],
        workspaceID: "local", source: "linear",
        keep: ["NEW-1", "NEW-2"], reconcile: true, allowEmptyKeep: false)
    guard let o1 = try fetchByExt(queue, "OLD-1"),
          let o2 = try fetchByExt(queue, "OLD-2") else { return false }
    let survived = o1.deletedAt == nil && o2.deletedAt == nil
    let landed = try fetchByExt(queue, "NEW-1") != nil   // upserts still applied
    return survived && landed && outcome.retired == 0
        && outcome.reconcileWithheld
        && outcome.withheldReason == .fullTurnover
        && outcome.priorCandidates == 2
}

// The override exists for a real Linear-side migration, where every identifier
// legitimately changed at once.
check("actionable sync: allowFullTurnover lets reconcile run") {
    let (store, queue) = try makeStore()
    try store.applyActionableSync(
        rows: [lrow("OLD-1", "started")],
        workspaceID: "local", source: "linear",
        keep: ["OLD-1"], reconcile: false, allowEmptyKeep: false)
    let outcome = try store.applyActionableSync(
        rows: [lrow("NEW-1", "started")],
        workspaceID: "local", source: "linear",
        keep: ["NEW-1"], reconcile: true, allowEmptyKeep: false,
        allowFullTurnover: true)
    guard let old = try fetchByExt(queue, "OLD-1") else { return false }
    return old.deletedAt != nil && outcome.retired == 1
        && !outcome.reconcileWithheld
}

// A first sync has nothing to protect, so the guard must stay out of the way —
// otherwise it would appear to fire on every fresh install.
check("actionable sync: an empty prior set does not trip the guard") {
    let (store, queue) = try makeStore()
    let outcome = try store.applyActionableSync(
        rows: [lrow("NEW-1", "started")],
        workspaceID: "local", source: "linear",
        keep: ["NEW-1"], reconcile: true, allowEmptyKeep: false)
    return try fetchByExt(queue, "NEW-1") != nil
        && !outcome.reconcileWithheld && outcome.priorCandidates == 0
}

// Ordinary churn: one surviving issue is enough to prove the fetch is real, so
// the rest reconcile as before.
check("actionable sync: one matching key is enough to reconcile") {
    let (store, queue) = try makeStore()
    try store.applyActionableSync(
        rows: [lrow("KEEP-1", "started"), lrow("GONE-1", "started")],
        workspaceID: "local", source: "linear",
        keep: ["KEEP-1", "GONE-1"], reconcile: false, allowEmptyKeep: false)
    let outcome = try store.applyActionableSync(
        rows: [lrow("KEEP-1", "started")],
        workspaceID: "local", source: "linear",
        keep: ["KEEP-1"], reconcile: true, allowEmptyKeep: false)
    guard let gone = try fetchByExt(queue, "GONE-1") else { return false }
    return gone.deletedAt != nil && !outcome.reconcileWithheld
        && outcome.retired == 1
}

// Resolved rows are not reconcile candidates, so an overlap consisting only of a
// resolved row is still a full turnover — the guard has to measure the same set
// reconcile acts on, which is what the shared predicate is for.
check("actionable sync: a resolved row does not count as a match") {
    let (store, queue) = try makeStore()
    let done = "2026-06-08T15:30:00.000Z"
    try store.applyActionableSync(
        rows: [lrow("DONE-1", "completed", completedAt: done),
               lrow("OPEN-1", "started")],
        workspaceID: "local", source: "linear",
        keep: ["DONE-1", "OPEN-1"], reconcile: false, allowEmptyKeep: false)
    // Incoming overlaps only the resolved row, which reconcile would never touch.
    let outcome = try store.applyActionableSync(
        rows: [lrow("DONE-1", "completed", completedAt: done)],
        workspaceID: "local", source: "linear",
        keep: ["DONE-1"], reconcile: true, allowEmptyKeep: false)
    guard let open = try fetchByExt(queue, "OPEN-1") else { return false }
    return open.deletedAt == nil && outcome.reconcileWithheld
        && outcome.withheldReason == .fullTurnover
}

// MARK: - Triage and upstream regression

// Triage is assigned, unresolved work that wants looking at, so it lands like
// started/unstarted rather than in the icebox with backlog. Before it was synced
// at all it fell out of `keep` and was retired on every run.
check("actionable sync: a triage issue lands active, not iceboxed") {
    let (store, queue) = try makeStore()
    try store.applyActionableSync(
        rows: [lrow("TRI-1", "triage")],
        workspaceID: "local", source: "linear",
        keep: ["TRI-1"], reconcile: false, allowEmptyKeep: false)
    guard let item = try fetchByExt(queue, "TRI-1") else { return false }
    let onActive = try store.fetchActive(type: .todo).contains { $0.id == item.id }
    return item.iceboxedAt == nil && item.resolvedAt == nil && onActive
}

// A regression restores placement rather than flattening it. This is why
// clearing the day was rejected: a future-scheduled row that completes and then
// regresses has to come back to its own day, not to Today.
check("actionable sync: a regression keeps its day and its icebox") {
    let (store, queue) = try makeStore()
    let done = "2026-06-08T15:30:00.000Z"
    let day = CivilDate(ISO8601DateFormatter().date(from: "2026-07-01T12:00:00Z")!)
    try store.applyActionableSync(
        rows: [lrow("REG-1", "completed", completedAt: done)],
        workspaceID: "local", source: "linear",
        keep: ["REG-1"], reconcile: false, allowEmptyKeep: false)
    guard let created = try fetchByExt(queue, "REG-1") else { return false }
    try store.reschedule(id: created.id, to: day)
    try store.setIceboxed(id: created.id, true)
    // Regresses upstream: no completedAt this time.
    try store.applyActionableSync(
        rows: [lrow("REG-1", "backlog")],
        workspaceID: "local", source: "linear",
        keep: ["REG-1"], reconcile: false, allowEmptyKeep: false)
    guard let after = try store.fetch(id: created.id) else { return false }
    return after.resolvedAt == nil        // resolution cleared
        && after.scheduledOn == day       // its own day survives
        && after.iceboxedAt != nil        // icebox membership survives
}

// The DEV-12 shape: completed, never rescheduled, then regressed to backlog.
// The stale completion day goes and the row is iceboxed, so it rejoins its
// backlog siblings instead of sitting weeks overdue on Today.
check("actionable sync: a backlog regression clears the stamped day and iceboxes") {
    let (store, queue) = try makeStore()
    let done = "2026-06-08T15:30:00.000Z"
    try store.applyActionableSync(
        rows: [lrow("DEV-12", "completed", completedAt: done)],
        workspaceID: "local", source: "linear",
        keep: ["DEV-12"], reconcile: false, allowEmptyKeep: false)
    try store.applyActionableSync(
        rows: [lrow("DEV-12", "backlog")],
        workspaceID: "local", source: "linear",
        keep: ["DEV-12"], reconcile: false, allowEmptyKeep: false)
    guard let after = try fetchByExt(queue, "DEV-12") else { return false }
    return after.resolvedAt == nil && after.scheduledOn == nil
        && after.iceboxedAt != nil
}

// Regressing to a non-backlog state clears the stamp but does NOT icebox — only
// backlog means deferred.
check("actionable sync: a non-backlog regression clears the day without iceboxing") {
    let (store, queue) = try makeStore()
    let done = "2026-06-08T15:30:00.000Z"
    try store.applyActionableSync(
        rows: [lrow("REO-1", "completed", completedAt: done)],
        workspaceID: "local", source: "linear",
        keep: ["REO-1"], reconcile: false, allowEmptyKeep: false)
    try store.applyActionableSync(
        rows: [lrow("REO-1", "started")],
        workspaceID: "local", source: "linear",
        keep: ["REO-1"], reconcile: false, allowEmptyKeep: false)
    guard let after = try fetchByExt(queue, "REO-1") else { return false }
    return after.resolvedAt == nil && after.scheduledOn == nil
        && after.iceboxedAt == nil
}

// Icebox membership on a LIVE row stays local. A backlog item the user took out
// of the icebox must not be put back on the next sync — which is why the icebox
// rule is gated on the un-resolve rather than on `status_type` alone.
check("actionable sync: an un-iceboxed live backlog row stays out of the icebox") {
    let (store, queue) = try makeStore()
    try store.applyActionableSync(
        rows: [lrow("BL-1", "backlog")],
        workspaceID: "local", source: "linear",
        keep: ["BL-1"], reconcile: false, allowEmptyKeep: false)
    guard let created = try fetchByExt(queue, "BL-1") else { return false }
    try store.setIceboxed(id: created.id, false)   // user pulls it out
    try store.applyActionableSync(
        rows: [lrow("BL-1", "backlog")],
        workspaceID: "local", source: "linear",
        keep: ["BL-1"], reconcile: false, allowEmptyKeep: false)
    guard let after = try store.fetch(id: created.id) else { return false }
    return after.iceboxedAt == nil
}

// The other direction is unchanged: a completion is never re-stamped.
check("actionable sync: an already-resolved row keeps its completion day") {
    let (store, queue) = try makeStore()
    let first = "2026-06-08T15:30:00.000Z"
    let later = "2026-06-20T09:00:00.000Z"
    let firstDay = CivilDate(ISO8601DateFormatter().date(from: "2026-06-08T15:30:00Z")!)
    try store.applyActionableSync(
        rows: [lrow("FIX-1", "completed", completedAt: first)],
        workspaceID: "local", source: "linear",
        keep: ["FIX-1"], reconcile: false, allowEmptyKeep: false)
    try store.applyActionableSync(
        rows: [lrow("FIX-1", "completed", completedAt: later)],
        workspaceID: "local", source: "linear",
        keep: ["FIX-1"], reconcile: false, allowEmptyKeep: false)
    guard let after = try fetchByExt(queue, "FIX-1") else { return false }
    return after.scheduledOn == firstDay
}

// And the regression un-pins it from reconcile immunity, which was the second
// half of the DEV-12 bug: a permanently-resolved row could never be retired.
check("actionable sync: a regressed row becomes a reconcile candidate again") {
    let (store, queue) = try makeStore()
    let done = "2026-06-08T15:30:00.000Z"
    try store.applyActionableSync(
        rows: [lrow("IMM-1", "completed", completedAt: done),
               lrow("ANCHOR", "started")],
        workspaceID: "local", source: "linear",
        keep: ["IMM-1", "ANCHOR"], reconcile: false, allowEmptyKeep: false)
    // Regress it, so it stops being spared.
    try store.applyActionableSync(
        rows: [lrow("IMM-1", "backlog"), lrow("ANCHOR", "started")],
        workspaceID: "local", source: "linear",
        keep: ["IMM-1", "ANCHOR"], reconcile: false, allowEmptyKeep: false)
    // Now drop it from the assigned set; ANCHOR keeps the guard satisfied.
    try store.applyActionableSync(
        rows: [lrow("ANCHOR", "started")],
        workspaceID: "local", source: "linear",
        keep: ["ANCHOR"], reconcile: true, allowEmptyKeep: false)
    guard let imm = try fetchByExt(queue, "IMM-1") else { return false }
    return imm.deletedAt != nil
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

// 27. completeActionable stamps resolved_at and always re-homes scheduled_on to
//     today, overwriting any prior day (a previously set day or none alike). Keeps
//     iceboxed_at so the completion stays reversible from the icebox, and drops
//     resolved rows from fetchIceboxed.
check("completeActionable: always stamps today, keeps iceboxed") {
    let (store, _) = try makeStore()
    let today = CivilDate(Date())
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
    return d.resolvedAt != nil && d.scheduledOn == today && d.iceboxedAt != nil
        && b.resolvedAt != nil && b.scheduledOn == today && b.iceboxedAt != nil
        && gone
}

// 28. reopenActionable clears resolved_at only; scheduled_on and iceboxed_at are
//     durable, so a row returns to the day it carried and back into fetchIceboxed.
//     Built resolved directly so this exercises reopen in isolation, independent of
//     completeActionable's today-stamp.
check("reopenActionable: clears resolution, preserves schedule") {
    let (store, _) = try makeStore()
    let day = CivilDate(year: 2026, month: 6, day: 20)
    let item = newItem(type: .todo, typeData: .todo(ActionableData()),
                       scheduledOn: day, iceboxedAt: Date(), resolvedAt: Date())
    try store.create(item)
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
//     the focused row; empty when nothing is focused, and empty when that group is
//     collapsed (the selection would render nowhere).
check("ActionableListNavigation.idsInGroup: scopes to focused row's group") {
    func ice(_ list: String?, _ title: String) -> Item {
        newItem(type: .todo, typeData: .todo(ActionableData(listName: list)), title: title)
    }
    let items = [ice(nil, "free"), ice("alpha", "a1"), ice("alpha", "a2"), ice("Zeta", "z1")]
    let groups = ActionableGrouping.groups(items: items)
    let alpha = groups.first { $0.listName == "alpha" }!
    let a1 = alpha.items.first { $0.title == "a1" }!
    let alphaIDs = Set(alpha.items.map { $0.id })
    return Set(ActionableListNavigation.idsInGroup(of: a1.id, groups, collapsed: [])) == alphaIDs
        && ActionableListNavigation.idsInGroup(of: nil, groups, collapsed: []).isEmpty
        // Focus inside a collapsed group selects nothing — *a may not seed a
        // selection no row can show, the refusal `x` already makes.
        && ActionableListNavigation.idsInGroup(
            of: a1.id, groups, collapsed: ["alpha"]).isEmpty
        // Some other group being collapsed is irrelevant to this one.
        && Set(ActionableListNavigation.idsInGroup(
            of: a1.id, groups, collapsed: ["Zeta"])) == alphaIDs
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

// 41. The schedule's fetch surfaces scheduled actionables alongside events, keeps
//     resolved ones (struck history on their day), excludes iceboxed. The resolved
//     row is built directly on `day` so it stays in-window — completion itself
//     re-homes to today, a separate concern covered by #27.
check("fetchActive(from:to:): scheduled actionables incl. resolved, excl. iceboxed") {
    let (store, _) = try makeStore()
    let day = CivilDate(year: 2026, month: 6, day: 15)
    let todo = newItem(type: .todo, typeData: .todo(ActionableData()), title: "todo", scheduledOn: day)
    let event = newItem(type: .calendar, typeData: .calendar(CalendarData()),
                        source: "gcal", externalID: "e", scheduledOn: day)
    let done = newItem(type: .todo, typeData: .todo(ActionableData()), title: "done",
                       scheduledOn: day, resolvedAt: Date())
    let boxed = newItem(type: .todo, typeData: .todo(ActionableData()), title: "boxed", scheduledOn: day)
    for i in [todo, event, done, boxed] { try store.create(i) }
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

// 41c. ScheduleAgenda.days hard-caps the materialized range at `through`. A
//      single far-future item must not generate one empty section per
//      intervening day — the unbounded fill that pinned SwiftUI's layout pass
//      and beach-balled the agenda. Days stop at the horizon; the far item
//      renders only once the window extends to cover it.
check("ScheduleAgenda.days: `through` hard-caps the materialized range") {
    let today = CivilDate(year: 2026, month: 6, day: 13)
    let through = today.adding(days: 10)
    let near = newItem(type: .todo, typeData: .todo(ActionableData()),
                       title: "near", scheduledOn: today.adding(days: 3))
    let far = newItem(type: .calendar, typeData: .calendar(CalendarData()),
                      source: "gcal", externalID: "far",
                      scheduledOn: CivilDate(year: 2027, month: 6, day: 13))
    let days = ScheduleAgenda.days(
        items: [near, far], from: today, through: through, today: today)
    // Bounded to today…through inclusive (11 days), not ~365 days out.
    let cappedAtHorizon = days.last?.date == through && days.count == 11
    let nearShown = days.contains {
        $0.actionableGroups.flatMap(\.items).contains { $0.id == near.id }
    }
    let farOmitted = !days.contains { $0.events.contains { $0.id == far.id } }
    return cappedAtHorizon && nearShown && farOmitted
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

// 45. BriefingSnapshot.current: the today list (unscheduled + today-scheduled +
//     today's calendar events with their times, iceboxed excluded), the
//     lookahead window, and the icebox summary.
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
    let cal = newItem(type: .calendar,
                      typeData: .calendar(CalendarData(startAt: Date(), allDay: false)),
                      source: "gcal", externalID: "e1", scheduledOn: today)
    let boxed = newItem(type: .todo, typeData: .todo(ActionableData()), iceboxedAt: Date())
    for i in [todo, rem, soon, far, cal, boxed] { try store.create(i) }

    let snap = try BriefingSnapshot.current(store: store, asOf: today)
    let upcomingTitles = snap.upcoming.map { $0.title }
    let calRow = snap.today.first { $0.id == cal.id }
    return snap.today.contains { $0.id == todo.id }        // unscheduled accumulates
        && snap.today.contains { $0.id == rem.id }         // today-scheduled reminder
        && calRow?.kind == "calendar" && calRow?.startAt != nil  // calendar w/ its time
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
        && spend.intervalSeconds == 3600 && !spend.enabled
        && spend.windowStart == "07:05" && spend.windowEnd == "19:05"
        && priority.triggerType == "recurring" && priority.cadenceKind == "interval"
        && priority.intervalSeconds == 3600 && !priority.enabled
        && priority.windowStart == "10:15" && priority.windowEnd == "16:30"
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

// MARK: - Announcement catch-up decisions

/// A timed calendar item starting `minutes` from now (negative = already
/// started), for the catch-up checks below.
func calendarItem(_ title: String, startingIn minutes: Double) -> Item {
    newItem(
        type: .calendar,
        typeData: .calendar(CalendarData(
            startAt: Date().addingTimeInterval(minutes * 60), allDay: false)),
        title: title)
}

// TemporaryMuteRule: each temporary reason silences on its own.
check("TemporaryMuteRule: mic, away, and manual each silence") {
    TemporaryMuteRule.isSilenced(
        muteWhileMicInUse: true, micInUse: true,
        isAway: false, isManuallyMuted: false)
        && TemporaryMuteRule.isSilenced(
            muteWhileMicInUse: false, micInUse: false,
            isAway: true, isManuallyMuted: false)
        && TemporaryMuteRule.isSilenced(
            muteWhileMicInUse: false, micInUse: false,
            isAway: false, isManuallyMuted: true)
}

// TemporaryMuteRule: a live mic is ignored when the user opted out of
// mic-muting — the whole point of the toggle.
check("TemporaryMuteRule: mic ignored when mic-muting is off") {
    !TemporaryMuteRule.isSilenced(
        muteWhileMicInUse: false, micInUse: true,
        isAway: false, isManuallyMuted: false)
}

// TemporaryMuteRule: nothing set means nothing temporary.
check("TemporaryMuteRule: quiet inputs are not silenced") {
    !TemporaryMuteRule.isSilenced(
        muteWhileMicInUse: true, micInUse: false,
        isAway: false, isManuallyMuted: false)
}

// catchUps: a meeting already started is dropped — the user most likely went
// to it, which makes the reminder redundant.
check("catchUps: a started meeting announces nothing") {
    let past = calendarItem("Standup", startingIn: -3)
    return CalendarAnnouncementDecisions.catchUps(
        items: [past], missedItemIDs: [past.id], now: Date()).isEmpty
}

// catchUps: an upcoming meeting is re-announced with a lead recomputed from
// now, not the lead that was swallowed.
check("catchUps: upcoming meeting uses a freshly computed lead") {
    let soon = calendarItem("Retro", startingIn: 4)
    let out = CalendarAnnouncementDecisions.catchUps(
        items: [soon], missedItemIDs: [soon.id], now: Date())
    return out.count == 1 && out[0].minutesBefore == 4
}

// catchUps: a meeting starting right now reads as zero, which
// SpeechAnnouncer.eventPhrase renders "starting now".
check("catchUps: a meeting starting now is lead zero") {
    let starting = calendarItem("Sync", startingIn: 0)
    let out = CalendarAnnouncementDecisions.catchUps(
        items: [starting], missedItemIDs: [starting.id], now: Date())
    return out.count == 1 && out[0].minutesBefore == 0
}

// catchUps: several missed meetings come back soonest first.
check("catchUps: multiple upcoming meetings are ordered soonest first") {
    let far = calendarItem("Planning", startingIn: 25)
    let near = calendarItem("One on one", startingIn: 6)
    let mid = calendarItem("Review", startingIn: 12)
    let out = CalendarAnnouncementDecisions.catchUps(
        items: [far, near, mid],
        missedItemIDs: [far.id, near.id, mid.id], now: Date())
    return out.map(\.title) == ["One on one", "Review", "Planning"]
}

// catchUps: only the missed set is replayed; an untouched meeting stays quiet.
check("catchUps: meetings outside the missed set are ignored") {
    let missed = calendarItem("Missed", startingIn: 5)
    let other = calendarItem("Other", startingIn: 5)
    let out = CalendarAnnouncementDecisions.catchUps(
        items: [missed, other], missedItemIDs: [missed.id], now: Date())
    return out.map(\.title) == ["Missed"]
}

// catchUps: one meeting yields one announcement however many of its leads the
// silence swallowed — the recomputed lead is the same answer for all of them.
check("catchUps: a meeting appears once regardless of missed leads") {
    let m = calendarItem("Standup", startingIn: 3)
    let out = CalendarAnnouncementDecisions.catchUps(
        items: [m], missedItemIDs: [m.id], now: Date())
    return out.count == 1
}

// catchUps: an all-day item has no start to count toward.
check("catchUps: all-day items are skipped") {
    let allDay = newItem(
        type: .calendar, typeData: .calendar(CalendarData(allDay: true)),
        title: "Holiday")
    return CalendarAnnouncementDecisions.catchUps(
        items: [allDay], missedItemIDs: [allDay.id], now: Date()).isEmpty
}

// due: the existing lead-matching behaviour survives the move out of the
// service.
check("due: a lead minute matches, a non-lead minute does not") {
    var settings = CalendarAnnouncementSettings.defaults
    settings.leadMinutes = [5]
    settings.announceStart = false
    let at5 = calendarItem("Retro", startingIn: 5)
    let at7 = calendarItem("Retro", startingIn: 7)
    return CalendarAnnouncementDecisions.due(
        items: [at5], now: Date(), settings: settings).count == 1
        && CalendarAnnouncementDecisions.due(
            items: [at7], now: Date(), settings: settings).isEmpty
}

// due: a past event never matches, even at a lead the settings select.
check("due: a started meeting is never due") {
    var settings = CalendarAnnouncementSettings.defaults
    settings.leadMinutes = [5]
    settings.announceStart = true
    let past = calendarItem("Standup", startingIn: -5)
    return CalendarAnnouncementDecisions.due(
        items: [past], now: Date(), settings: settings).isEmpty
}

// MARK: - Keystroke cheat sheet

/// A context snapshot with everything quiet unless overridden.
func ksCtx(
    tab: MainTab = .icebox,
    readerOpen: Bool = false,
    hasSelection: Bool = false,
    terminalPaneFocused: Bool = false,
    editableTextFocused: Bool = false,
    findBarOpen: Bool = false
) -> KeystrokeContext {
    KeystrokeContext(
        tab: tab, readerOpen: readerOpen, hasSelection: hasSelection,
        terminalPaneFocused: terminalPaneFocused,
        editableTextFocused: editableTextFocused, findBarOpen: findBarOpen)
}

// Availability: a batch chord is live on its own tab with a selection, and
// nowhere else.
check("availability: selection chord needs its tab and a selection") {
    let a = KeystrokeAvailability.tabsWithSelection([.icebox])
    return a.isActive(in: ksCtx(tab: .icebox, hasSelection: true))
        && !a.isActive(in: ksCtx(tab: .icebox, hasSelection: false))
        && !a.isActive(in: ksCtx(tab: .trash, hasSelection: true))
}

// Availability: an open reader suppresses the list chords beneath it.
check("availability: list chords go inactive while the reader is open") {
    !KeystrokeAvailability.tabs([.icebox])
        .isActive(in: ksCtx(tab: .icebox, readerOpen: true))
}

// Availability: typing in a field suppresses the single-key chords. The
// snapshot is taken before the sheet's own field takes focus, so this
// describes the surface behind the sheet.
check("availability: an editable field suppresses list chords") {
    !KeystrokeAvailability.tabs([.icebox])
        .isActive(in: ksCtx(tab: .icebox, editableTextFocused: true))
}

// Availability: view switching stands aside for a focused editor.
check("availability: view switch yields to a focused editor") {
    KeystrokeAvailability.viewSwitch.isActive(in: ksCtx())
        && !KeystrokeAvailability.viewSwitch
            .isActive(in: ksCtx(editableTextFocused: true))
}

// Availability: popover entries are documented but never active, since the
// sheet only opens from the main window.
check("availability: popover entries are never active") {
    !KeystrokeAvailability.panel("Capture popover").isActive(in: ksCtx())
}

// Availability: a global hotkey is live no matter the surface.
check("availability: global hotkeys are always active") {
    KeystrokeAvailability.always
        .isActive(in: ksCtx(readerOpen: true, editableTextFocused: true))
}

// Availability: the pane-acting commands follow the Terminal view, not focus.
// They resolve their pane from the focus memory when nothing holds first
// responder, so the caret sitting in the find bar — or anywhere else — does not
// stop them, and the sheet has to agree.
check("availability: terminal-tab commands ignore where focus sits") {
    let a = KeystrokeAvailability.terminalTab
    return a.isActive(in: ksCtx(tab: .terminal))
        && a.isActive(in: ksCtx(tab: .terminal, findBarOpen: true))
        && a.isActive(in: ksCtx(tab: .terminal, editableTextFocused: true))
        && !a.isActive(in: ksCtx(tab: .icebox))
}

// Availability: and they are not the focus-strict case, which the same
// commands used to carry — that one goes dark the moment the find panel takes
// key, which is exactly when they still work.
check("availability: terminal-tab is not terminal-pane") {
    KeystrokeAvailability.terminalTab.isActive(in: ksCtx(tab: .terminal))
        && !KeystrokeAvailability.terminalPane
            .isActive(in: ksCtx(tab: .terminal))
}

// Opening section: the sheet lands on the reader when one is open, on the
// terminal section from the terminal tab, and on the lists otherwise.
check("opening section: follows the snapshot") {
    KeystrokeSection.opening(for: ksCtx(tab: .terminal)) == .terminal
        && KeystrokeSection.opening(for: ksCtx(tab: .icebox)) == .lists
        && KeystrokeSection.opening(
            for: ksCtx(tab: .icebox, readerOpen: true)) == .reader
}

// Fuzzy: an empty query matches everything, so an unfiltered sheet is full.
check("fuzzy: empty query matches") {
    FuzzyMatch.matches("Move to Icebox", query: "")
}

// Fuzzy: a plain substring matches.
check("fuzzy: substring matches") {
    FuzzyMatch.matches("Move to Icebox", query: "icebox")
}

// Fuzzy: scattered subsequence matches — "mti" for Move To Icebox.
check("fuzzy: scattered subsequence matches") {
    FuzzyMatch.matches("Move to Icebox", query: "mti")
}

// Fuzzy: out-of-order characters do not match.
check("fuzzy: out-of-order query does not match") {
    !FuzzyMatch.matches("Move to Icebox", query: "xobeci")
}

// Fuzzy: matching is case-insensitive in both directions.
check("fuzzy: case-insensitive") {
    FuzzyMatch.matches("Move to Icebox", query: "ICEBOX")
        && FuzzyMatch.matches("MOVE TO ICEBOX", query: "icebox")
}

// Fuzzy: a query longer than the candidate cannot match.
check("fuzzy: over-long query does not match") {
    FuzzyMatch.score("a i", query: "a icebox") == nil
}

// Fuzzy: a contiguous run outranks the same letters scattered.
check("fuzzy: contiguous beats scattered") {
    let contiguous = FuzzyMatch.score("Copy", query: "cop")
    let scattered = FuzzyMatch.score("Change list opener", query: "cop")
    guard let c = contiguous, let s = scattered else { return false }
    return c > s
}

// Fuzzy: a chord keystroke is searchable, so "ai" finds `a i`.
check("fuzzy: a chord keystroke is searchable") {
    FuzzyMatch.matches("a i", query: "ai")
}

// Ranges: the reported offsets are the characters that actually matched — what
// the scratch feed highlights.
check("fuzzy: reports matched offsets in order") {
    guard let r = FuzzyMatch.result("Move to Icebox", query: "mti")
    else { return false }
    return r.matchedOffsets == [0, 5, 8]
}

// Ranges: a failed match yields nothing to highlight.
check("fuzzy: a failed match yields no result") {
    FuzzyMatch.result("Move to Icebox", query: "zzz") == nil
}

// Ranges: an empty query matches with no highlights, so an unfiltered feed
// renders as plain text.
check("fuzzy: empty query highlights nothing") {
    FuzzyMatch.result("anything", query: "")?.matchedOffsets == []
}

// Ranges: offsets index the candidate positionally, so a highlight cannot slip
// when the query's case differs from the text's.
check("fuzzy: offsets align on mixed-case candidates") {
    guard let r = FuzzyMatch.result("Move To Icebox", query: "TI")
    else { return false }
    return r.matchedOffsets == [5, 8]
}

// Ranges: a newline counts as a word boundary, so the first word of each line of
// a multi-line note body scores as a word start.
check("fuzzy: a newline starts a word") {
    guard let across = FuzzyMatch.score("alpha\nbeta", query: "b"),
          let mid = FuzzyMatch.score("alphaxbeta", query: "b")
    else { return false }
    return across > mid
}

// MARK: - Term matching (the scratch feed's search)

/// The reported cases, verbatim: a three-bullet note, a note whose first word
/// starts "th", one containing "the" mid-word, and one whose "e" precedes its
/// "th".
let bullets = "* one\n* two\n* three"
let third = "third note"
let another = "another test item"
let precedingE = "test item\n\n`This is a thing`"

// One term is a literal: "the" appears inside "another" but nowhere in the
// others, since neither "three" nor "third" contains it contiguously.
check("fuzzy/terms: one term is a contiguous literal") {
    FuzzyMatch.matches(another, query: "the", scope: .terms)
        && !FuzzyMatch.matches(bullets, query: "the", scope: .terms)
        && !FuzzyMatch.matches(third, query: "the", scope: .terms)
}

// A space is a gap: "th e" is `th` then `e` somewhere after it.
check("fuzzy/terms: a space allows a gap between terms") {
    FuzzyMatch.matches(bullets, query: "th e", scope: .terms)
        && FuzzyMatch.matches(third, query: "th e", scope: .terms)
        && FuzzyMatch.matches(another, query: "th e", scope: .terms)
}

// Order is what the gap does NOT relax. This note holds both fragments, but its
// only "e" comes before its only "th", so it must not match.
check("fuzzy/terms: a later term must follow the earlier one") {
    !FuzzyMatch.matches(precedingE, query: "th e", scope: .terms)
}

// "th e" over the bullets highlights inside "three" — the third line — rather
// than pairing "th" there with an earlier "e".
check("fuzzy/terms: the gap match lands after the first term") {
    guard let r = FuzzyMatch.result(bullets, query: "th e", scope: .terms)
    else { return false }
    let th = bullets.range(of: "three")!
    let start = bullets.distance(from: bullets.startIndex,
                                 to: th.lowerBound)
    // t, h from "three", then its first e — all within that word.
    return r.matchedOffsets == [start, start + 1, start + 3]
}

// Terms may span more than two: each just has to follow the last.
check("fuzzy/terms: three terms match in order") {
    FuzzyMatch.matches(another, query: "an te it", scope: .terms)
        && !FuzzyMatch.matches(another, query: "it te an", scope: .terms)
}

// Offsets are candidate-relative, so the highlight lands where the text is.
check("fuzzy/terms: offsets are candidate-relative") {
    guard let r = FuzzyMatch.result(another, query: "the", scope: .terms)
    else { return false }
    return r.matchedOffsets == [3, 4, 5]
}

// A whitespace-only query has no terms, so everything matches and nothing
// highlights.
check("fuzzy/terms: a blank query matches") {
    FuzzyMatch.matches("anything at all", query: "  ", scope: .terms)
        && FuzzyMatch.result("anything", query: "", scope: .terms)?
            .matchedOffsets == []
}

// The two scopes still differ as documented. Nothing in the app reads a whole
// label as a subsequence any more — the cheat sheet gave that up because it
// answered typos with confidently wrong rows — but the scope stays, and this is
// what pins the distinction the term rule is defined against.
check("fuzzy: subsequence still spans, unlike terms") {
    FuzzyMatch.matches("Move to Icebox", query: "mti")
        && !FuzzyMatch.matches("Move to Icebox", query: "mti", scope: .terms)
}

// MARK: - Cheat sheet search

/// A slice of the real catalog's shape: all four searchable fields, over rows
/// whose labels, chords and conditions overlap the way the catalog's genuinely
/// do — the long shared condition is what a loose rule feeds on.
let sheetRows: [KeystrokeSearch.Candidate] = [
    .init(label: "Delete", keys: "a d", section: "Lists",
          condition: "in Schedule, Icebox, Trash, with a selection"),
    .init(label: "Delete permanently", keys: "a d", section: "Lists",
          condition: "in Trash, with a selection"),
    .init(label: "Restore / Reopen", keys: "a r", section: "Lists",
          condition: "in Schedule, Icebox, Trash, with a selection"),
    .init(label: "Move to Icebox", keys: "a i", section: "Lists",
          condition: "in Schedule, Icebox, Trash, with a selection"),
    .init(label: "Add or change list", keys: "l l", section: "Lists",
          condition: "in Schedule, Icebox, Trash, with a selection"),
    .init(label: "Leave input mode (discards the draft)", keys: "esc",
          section: "Scratch", condition: "in Scratch"),
    .init(label: "Copy to clipboard", keys: "a c", section: "Lists",
          condition: "in Schedule, Icebox, Trash, with a selection"),
]

/// The labels a query keeps, in catalog order.
func sheetMatches(_ query: String) -> [String] {
    zip(sheetRows, KeystrokeSearch.hits(sheetRows, query: query))
        .compactMap { $1 == nil ? nil : $0.label }
}

// The reported bug, and the reason the fallback pass is gone: "scrat" answered
// with "Leave input mode (discards the draft)", its five letters read across
// three words. A query matches inside a word, and only a typed space crosses one.
//
// "cardt" is a subsequence of that label and a substring of nothing, so it is
// exactly what the old rule would keep and the current one must not.
check("sheet search: letters scattered across words do not match") {
    KeystrokeSearch.hits(sheetRows, query: "cardt").allSatisfy { $0 == nil }
        && sheetMatches("mti").isEmpty
        && sheetMatches("adcl").isEmpty
}

// A word query answers with the rows that contain the word, and stops there.
check("sheet search: a word query matches only rows holding the word") {
    sheetMatches("del") == ["Delete", "Delete permanently"]
        && sheetMatches("clip") == ["Copy to clipboard"]
}

// The section and the condition are searchable too — they are the only place
// "scratch" or "trash" is written, and typing either should turn up that part of
// the sheet. Safe now that a field can only answer to words it contains: this
// same fixture is what made a subsequence rule match nearly everything.
check("sheet search: the section and the condition are searchable") {
    sheetMatches("scratch") == ["Leave input mode (discards the draft)"]
        && sheetMatches("trash").contains("Delete permanently")
        && !sheetMatches("trash").contains("Leave input mode (discards the draft)")
        && sheetMatches("selection").contains("Move to Icebox")
}

// A chord is found by typing its keys — including the space, which is the only
// thing that crosses from one key to the next.
check("sheet search: a chord is found by typing its keys with the space") {
    sheetMatches("a i").contains("Move to Icebox")
        && sheetMatches("esc") == ["Leave input mode (discards the draft)"]
        && sheetMatches("ai").isEmpty
}

// An empty or whitespace query is not a filter.
check("sheet search: an empty query keeps every row and highlights nothing") {
    let all = KeystrokeSearch.hits(sheetRows, query: "   ")
    return all.count == sheetRows.count
        && all.allSatisfy { $0 == KeystrokeSearch.Hit() }
}

/// The real catalog as candidates.
///
/// Literal keystrokes only — resolving a rebindable one needs KeyboardShortcuts,
/// which this target deliberately cannot see. The rebindable rows searching as if
/// unbound does not affect what the checks below assert.
func catalogCandidates() -> [KeystrokeSearch.Candidate] {
    KeystrokeCatalog.all.map { entry in
        var keys = ""
        if case .literal(let text) = entry.binding { keys = text }
        return KeystrokeSearch.Candidate(
            label: entry.label, keys: keys,
            section: entry.section.title,
            condition: entry.availability.conditionText)
    }
}

/// The real catalog's labels that a query keeps.
func catalogMatches(_ query: String) -> [String] {
    zip(
        KeystrokeCatalog.all,
        KeystrokeSearch.hits(catalogCandidates(), query: query)
    ).compactMap { $1 == nil ? nil : $0.label }
}

// The same property over the real corpus, which is where it broke. Asserted as
// an invariant rather than a row count so the catalog can grow: no row survives
// "del" unless one of its fields spells those letters out in a row. A rule that
// let the letters scatter used to return every selection-gated row through
// "Sche(d)ul(e) … se(l)ection".
check("sheet search: a word query stays narrow over the real catalog") {
    let candidates = catalogCandidates()
    let hits = KeystrokeSearch.hits(candidates, query: "del")
    let kept = zip(candidates, hits).compactMap { $1 == nil ? nil : $0 }
    return !kept.isEmpty && kept.allSatisfy { candidate in
        [candidate.label, candidate.keys, candidate.section, candidate.condition]
            .contains { $0.lowercased().contains("del") }
    }
}

// The font-size trio answers to every word in it. This is the whole reason those
// labels spell out "terminal font size" three times instead of leaning on the
// menu heading that says it once: the menu is never filtered, and these rows are
// — a search strips a row of its neighbours, and a lone "Bigger" then says
// nothing about what it resizes.
check("catalog: the terminal font rows answer to terminal, font and size") {
    let trio: Set<String> = [
        "Default terminal font size",
        "Bigger terminal font size",
        "Smaller terminal font size",
    ]
    return ["terminal", "font", "size", "font size", "terminal font size"]
        .allSatisfy { trio.isSubset(of: Set(catalogMatches($0))) }
}

// Offsets are candidate-relative and land per field, so a row tints exactly what
// the filter read and only that — including a row kept for its condition alone.
check("sheet search: offsets point at what matched, per field") {
    let rows = [
        KeystrokeSearch.Candidate(
            label: "Delete", keys: "a d", section: "Lists",
            condition: "in Trash, with a selection"),
    ]
    guard let onLabel = KeystrokeSearch.hits(rows, query: "del").first ?? nil,
          let onKeys = KeystrokeSearch.hits(rows, query: "a d").first ?? nil,
          let onCondition = KeystrokeSearch.hits(rows, query: "trash").first ?? nil
    else { return false }
    return onLabel.labelOffsets == [0, 1, 2]
        && onLabel.keysOffsets.isEmpty
        && onLabel.conditionOffsets.isEmpty
        // Two terms, so two landing points rather than a run.
        && onKeys.keysOffsets == [0, 2]
        && onKeys.labelOffsets.isEmpty
        && onCondition.conditionOffsets == [3, 4, 5, 6, 7]
        && onCondition.labelOffsets.isEmpty
}

check("catalog: no entry has an empty label or literal binding") {
    KeystrokeCatalog.all.allSatisfy { entry in
        guard !entry.label.trimmingCharacters(in: .whitespaces).isEmpty
        else { return false }
        if case .literal(let s) = entry.binding {
            return !s.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }
}

// Catalog: no literal keystroke is documented twice within one section under
// the same availability — that would be two rows claiming one key in one
// context. The same key under *different* availability is legitimate (`a d`
// means Done outside Trash and Delete inside it).
check("catalog: no duplicate literal binding within a section and context") {
    var seen: Set<String> = []
    for e in KeystrokeCatalog.all {
        guard case .literal(let keys) = e.binding else { continue }
        let key = "\(e.section.rawValue)|\(keys)|\(e.availability)"
        if seen.contains(key) { return false }
        seen.insert(key)
    }
    return true
}

// Catalog: every section the sheet can render has content, so no bare headers.
check("catalog: every section has at least one entry") {
    KeystrokeSection.allCases.allSatisfy { section in
        KeystrokeCatalog.all.contains { $0.section == section }
    }
}

// Catalog: the `a` leader vocabulary matches what the chord tables implement.
check("catalog: the a-leader chords are documented") {
    let documented = Set(KeystrokeCatalog.all.compactMap { e -> String? in
        guard case .literal(let k) = e.binding, k.hasPrefix("a ") else {
            return nil
        }
        return k
    })
    return ["a d", "a r", "a i", "a v", "a c", "a l", "a p"]
        .allSatisfy { documented.contains($0) }
}

// Catalog: the `l` leader vocabulary matches what the chord tables implement.
check("catalog: the l-leader chords are documented") {
    let documented = Set(KeystrokeCatalog.all.compactMap { e -> String? in
        guard case .literal(let k) = e.binding, k.hasPrefix("l ") else {
            return nil
        }
        return k
    })
    return ["l t", "l r", "l e", "l l", "l s", "l d", "l p"]
        .allSatisfy { documented.contains($0) }
}

// Catalog: list chords are scoped to the surfaces that actually install
// ActionableListChords — Terminal and Tasks install none.
check("catalog: list chords are not claimed on Terminal or Tasks") {
    !KeystrokeCatalog.listTabs.contains(.terminal)
        && !KeystrokeCatalog.listTabs.contains(.tasks)
}

// Catalog: every capture kind has a documented global hotkey.
check("catalog: every capture kind is documented") {
    CaptureKind.allCases.allSatisfy { kind in
        KeystrokeCatalog.all.contains { $0.binding == .capture(kind) }
    }
}

// MARK: - Scratch pad

/// A scratch entry with `body` as the text and a derived title, matching what
/// ScratchModel writes. `list` is stored verbatim (no trimming) — this is the
/// raw row builder, so a check can hand the accessors a value to normalize;
/// `ScratchItem.make` is the path that normalizes on the way in.
func scratchItem(_ text: String, list: String? = nil) -> Item {
    newItem(
        type: .scratch, typeData: .scratch(ScratchData(listName: list)),
        title: ScratchTitle.derive(from: text), body: text)
}

/// Stands in for `ScratchModel.Row` — the model is not in this target, and the
/// point of the grouping being generic is that it never needs to be. Identifiable
/// by the note's id, as the real row is, so a group of these navigates through
/// `ListGroup` exactly as the feed's own does.
struct SmokeScratchRow: Identifiable {
    let item: Item
    let matchedOffsets: [Int]
    var id: String { item.id }
}

/// Count the scratch feed straight from the store's public reader.
func scratchCount(_ store: GRDBItemStore, resolved: Bool) throws -> Int {
    try store.fetchScratch(resolved: resolved).count
}

// A note stored before scratch carried a list reads back unfiled, and an
// unfiled note writes no key at all — the payload is JSON in the shared
// type_data column, so the field is a read-time default rather than a schema
// change. This is the check standing in for the migration there isn't.
check("ScratchData: an absent listName decodes unfiled and re-encodes absent") {
    let json = #"{"kind":"scratch","data":{}}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(ItemTypeData.self, from: json)
    guard case .scratch(let d) = decoded, d.listName == nil else { return false }
    let bare = String(data: try JSONEncoder().encode(decoded), encoding: .utf8) ?? ""
    let listed = String(
        data: try JSONEncoder().encode(ItemTypeData.scratch(
            ScratchData(listName: "Dev"))),
        encoding: .utf8) ?? ""
    return !bare.contains("listName") && listed.contains("listName")
}

// The list survives a write and a read, filed or not.
check("scratch: the list round-trips through the store, both ways") {
    let (store, _) = try makeStore()
    let listed = scratchItem("under a list", list: "Errands")
    let bare = scratchItem("no list")
    for i in [listed, bare] { try store.create(i) }
    guard let l = try store.fetch(id: listed.id),
          let b = try store.fetch(id: bare.id) else { return false }
    return l.typeData == .scratch(ScratchData(listName: "Errands"))
        && l.scratchListName == "Errands"
        && b.typeData == .scratch(ScratchData())
        && b.scratchListName == nil
}

// A note's list is read through its own accessor, and the actionable one stays
// blind to it — which is what keeps Trash, the one surface that groups notes
// and actionables together, filing every note under no list.
check("Item.scratchListName: normalizes, and the two accessors stay apart") {
    let padded = scratchItem("n", list: "  Errands  ")
    let blank = scratchItem("n", list: "   ")
    let todo = newItem(type: .todo, typeData: .todo(ActionableData(listName: "Dev")))
    return padded.scratchListName == "Errands"
        && blank.scratchListName == nil
        && padded.actionableListName == nil
        && todo.scratchListName == nil
        && ActionableGrouping.groups(items: [padded]).map { $0.listName } == [nil]
}

// The feed's sections: the unfiled group leads and is unnamed, named groups
// follow in text order (a leading emoji ignored, as in the schedule), and
// within a group the incoming order — capture time, or resolution time for the
// completed feed — is preserved, since notes have no position to re-sort by.
check("ScratchGrouping: unfiled first, named by text, incoming order kept") {
    let notes = [
        scratchItem("free-1"), scratchItem("z-1", list: "Zeta"),
        scratchItem("a-1", list: "🐜 AAA"), scratchItem("free-2"),
        scratchItem("z-2", list: "Zeta"),
    ]
    let groups = ScratchGrouping.groups(notes) { $0.scratchListName }
    guard let zeta = groups.first(where: { $0.listName == "Zeta" })
    else { return false }
    return groups.map { $0.listName } == [nil, "🐜 AAA", "Zeta"]
        && groups[0].entries.map { $0.title } == ["free-1", "free-2"]
        && zeta.entries.map { $0.title } == ["z-1", "z-2"]
        && !groups[0].isNamed && zeta.isNamed
        && groups[0].id == ScratchGrouping.noListID && zeta.id == "Zeta"
}

// Grouping is over rows, not items: each row pairs a note with the offsets its
// search matched, and those have to arrive in the group with it or the
// highlight goes dark the moment a query narrows the feed.
check("ScratchGrouping: a row's match offsets survive the grouping") {
    let rows = [
        SmokeScratchRow(item: scratchItem("alpha", list: "Dev"),
                        matchedOffsets: [0, 1]),
        SmokeScratchRow(item: scratchItem("beta"), matchedOffsets: [3]),
    ]
    let groups = ScratchGrouping.groups(rows) { $0.item.scratchListName }
    return groups.map { $0.listName } == [nil, "Dev"]
        && groups[0].entries.first?.matchedOffsets == [3]
        && groups[1].entries.first?.matchedOffsets == [0, 1]
}

// One traversal for both grouped surfaces: a scratch group walks through the same
// helpers the index lists use, reached by ListGroup. The collapse rule and the
// *a scoping are stated once, so they cannot drift apart per surface again — the
// drift that let *a seed a selection of rows a folded group was hiding.
check("ListGroup: the shared navigation walks a scratch group") {
    let rows = [
        SmokeScratchRow(item: scratchItem("free-1"), matchedOffsets: []),
        SmokeScratchRow(item: scratchItem("d-1", list: "Dev"), matchedOffsets: []),
        SmokeScratchRow(item: scratchItem("d-2", list: "Dev"), matchedOffsets: []),
    ]
    let groups = ScratchGrouping.groups(rows) { $0.item.scratchListName }
    let devIDs = [rows[1].id, rows[2].id]
    return ActionableListNavigation.visibleIDs(groups, collapsed: [])
            == [rows[0].id] + devIDs
        // A folded group leaves the traversal entirely, named or not.
        && ActionableListNavigation.visibleIDs(groups, collapsed: ["Dev"])
            == [rows[0].id]
        && ActionableListNavigation.visibleIDs(
            groups, collapsed: [ScratchGrouping.noListID]) == devIDs
        // *a takes the focused row's group…
        && ActionableListNavigation.idsInGroup(
            of: rows[1].id, groups, collapsed: []) == devIDs
        // …and nothing at all when that group is folded away.
        && ActionableListNavigation.idsInGroup(
            of: rows[1].id, groups, collapsed: ["Dev"]).isEmpty
        // The scratch sentinel and the actionable one stay distinct, so folding
        // the unfiled notes cannot fold the unfiled work.
        && ScratchGrouping.noListID != ActionableGroup(
            listName: nil, items: []).id
}

// One namespace of names: a name only a note uses suggests for a to-do and the
// reverse, so filing work beside the thought that started it is one word typed
// once. A discarded note's name drops off with it.
check("knownListNames: includes scratch names, excludes deleted notes") {
    let (store, _) = try makeStore()
    let note = scratchItem("n", list: "Parked")
    let todo = newItem(type: .todo, typeData: .todo(ActionableData(listName: "Dev")))
    let gone = scratchItem("g", list: "Archive")
    let blank = scratchItem("b", list: "   ")
    for i in [note, todo, gone, blank] { try store.create(i) }
    try store.softDelete(id: gone.id)
    return try store.knownListNames() == ["Dev", "Parked"]
}

// The two setters stay in their lanes — a note's list is setScratchListName's,
// an actionable's is setListName's — and crossing them is a no-op rather than a
// throw, so a batch spanning both kinds still writes the rows it can.
check("setScratchListName: sets, blank clears, and the setters don't cross") {
    let (store, _) = try makeStore()
    let note = scratchItem("n")
    let todo = newItem(type: .todo, typeData: .todo(ActionableData(listName: "Dev")))
    for i in [note, todo] { try store.create(i) }
    try store.setScratchListName(id: note.id, to: "  Parked  ")
    try store.setListName(id: note.id, to: "Ignored")
    try store.setScratchListName(id: todo.id, to: "Ignored")
    guard let parked = try store.fetch(id: note.id),
          let untouched = try store.fetch(id: todo.id) else { return false }
    try store.setScratchListName(id: note.id, to: "   ")
    guard let cleared = try store.fetch(id: note.id) else { return false }
    return parked.scratchListName == "Parked"
        && untouched.actionableListName == "Dev"
        && untouched.scratchListName == nil
        && cleared.scratchListName == nil
}

// The socket's list threads onto the note through the same maker the composer
// uses, trimmed on the way in so a blank one parks the note unfiled instead of
// storing a list nothing can display.
check("ScratchItem.make: threads a list, trims it, blank parks unfiled") {
    guard let listed = ScratchItem.make(
              text: "park this", listName: "  Errands  ", workspaceID: "local"),
          let bare = ScratchItem.make(text: "park this", workspaceID: "local"),
          let blank = ScratchItem.make(
              text: "park this", listName: "   ", workspaceID: "local")
    else { return false }
    return listed.typeData == .scratch(ScratchData(listName: "Errands"))
        && bare.typeData == .scratch(ScratchData())
        && blank.typeData == .scratch(ScratchData())
}

// Convert carries the note's list into the work it becomes — always, and with
// nothing to pass to decline it: filing a thought under a list already said
// where the work belongs. The name transfers normalized, so the promoted item
// groups under the heading the note sat beneath.
check("convertScratch: inherits the note's list into the actionable") {
    let (store, _) = try makeStore()
    let listed = scratchItem("ship the thing", list: "Dev")
    let padded = scratchItem("and this", list: "  Dev  ")
    let bare = scratchItem("some other thing")
    for i in [listed, padded, bare] { try store.create(i) }
    try store.convertScratch(id: listed.id, to: .todo, title: "Ship the thing",
                             body: nil, externalURL: "https://x.test/1")
    try store.convertScratch(id: padded.id, to: .explore, title: "And this",
                             body: nil, externalURL: nil)
    try store.convertScratch(id: bare.id, to: .reminder, title: "Some other thing",
                             body: nil, externalURL: nil)
    guard let l = try store.fetch(id: listed.id),
          let p = try store.fetch(id: padded.id),
          let b = try store.fetch(id: bare.id),
          case .todo(let ld) = l.typeData,
          case .reminder(let bd) = b.typeData else { return false }
    let grouped = ActionableGrouping.groups(items: [l, p]).map { $0.listName }
    return ld.listName == "Dev" && ld.externalURL == "https://x.test/1"
        && p.actionableListName == "Dev" && bd.listName == nil
        && grouped == ["Dev"]
}

// scratch: the kind round-trips through the store, payload and all.
check("round-trip a scratch item") {
    let (store, _) = try makeStore()
    let item = scratchItem("the full text")
    try store.create(item)
    let read = try store.fetch(id: item.id)
    return read?.type == "scratch"
        && read?.body == "the full text"
        && read?.typeData == .scratch(ScratchData())
}

// scratch is deliberately not actionable — the property every surface
// predicate depends on.
check("ItemType: scratch is not an actionable kind") {
    !ItemType.actionableCases.contains(.scratch)
        && ItemType.actionableCases.count == 3
}

// The SQL list stays in sync with the cases it derives from, so the seven
// predicates reading it cannot drift from the enum.
check("ItemType: actionable SQL list matches its cases") {
    ItemType.actionableSQLList == "'todo', 'reminder', 'explore'"
}

// Title: the first meaningful line becomes the title.
check("ScratchTitle: takes the first non-empty line") {
    ScratchTitle.derive(from: "first line\nsecond line") == "first line"
}

// Title: leading blank lines are skipped rather than yielding an empty title.
check("ScratchTitle: skips leading blank lines") {
    ScratchTitle.derive(from: "\n\n  real content\nmore") == "real content"
}

// Title: a whitespace-only body still yields something identifiable in Trash.
check("ScratchTitle: whitespace-only body falls back") {
    ScratchTitle.derive(from: "   \n\t\n") == ScratchTitle.fallback
        && ScratchTitle.derive(from: "") == ScratchTitle.fallback
}

// Title: a long single line is truncated with an ellipsis.
check("ScratchTitle: truncates a long line") {
    let title = ScratchTitle.derive(from: String(repeating: "x", count: 200))
    return title.count == ScratchTitle.maxLength + 1 && title.hasSuffix("…")
}

// Title: a pasted code block is titled by its first line, not mangled.
check("ScratchTitle: a pasted block titles from line one") {
    ScratchTitle.derive(from: "func foo() {\n  bar()\n}") == "func foo() {"
}

// Feed: open and completed are disjoint, and resolving moves an entry across.
check("scratch feed: resolve moves an entry from open to completed") {
    let (store, _) = try makeStore()
    let note = scratchItem("n")
    try store.create(note)
    guard try scratchCount(store, resolved: false) == 1,
          try scratchCount(store, resolved: true) == 0
    else { return false }
    try store.resolve(id: note.id)
    let open = try scratchCount(store, resolved: false)
    let done = try scratchCount(store, resolved: true)
    return open == 0 && done == 1
}

// Feed: unresolve brings it back to the open feed.
check("scratch feed: unresolve returns an entry to open") {
    let (store, _) = try makeStore()
    let note = scratchItem("n")
    try store.create(note)
    try store.resolve(id: note.id)
    try store.unresolve(id: note.id)
    return try scratchCount(store, resolved: false) == 1
}

// Feed: a trashed entry leaves both feeds.
check("scratch feed: a deleted entry leaves the feed") {
    let (store, _) = try makeStore()
    let note = scratchItem("n")
    try store.create(note)
    try store.softDelete(id: note.id)
    let open = try scratchCount(store, resolved: false)
    let done = try scratchCount(store, resolved: true)
    return open == 0 && done == 0
}

// Feed: put-back from Trash returns an entry to the open feed, since scratch
// has no icebox to land in.
check("scratch feed: put back from trash returns to open") {
    let (store, _) = try makeStore()
    let note = scratchItem("n")
    try store.create(note)
    try store.softDelete(id: note.id)
    try store.undelete(id: note.id)
    return try scratchCount(store, resolved: false) == 1
}

// Feed: newest first, so a fresh note lands at the top.
//
// `create` stamps `createdAt` itself, so the ages are set afterwards via
// `update` (which preserves it). Doing this by ordering two `create` calls
// would leave the assertion riding on whether the clock ticked between them —
// it passed and failed on consecutive runs before being pinned this way.
check("scratch feed: newest entry comes first") {
    let (store, _) = try makeStore()
    let anchor = Date()
    var rows: [Item] = []
    for (title, ageSeconds) in [("newest", 0.0), ("middle", 600.0),
                                ("oldest", 1200.0)] {
        let item = scratchItem(title)
        try store.create(item)
        guard var stored = try store.fetch(id: item.id) else { return false }
        stored.createdAt = anchor.addingTimeInterval(-ageSeconds)
        try store.update(stored)
        rows.append(stored)
    }
    return try store.fetchScratch(resolved: false).map(\.title)
        == ["newest", "middle", "oldest"]
}

// Trash: a deleted scratch entry joins the shared Trash alongside actionables.
check("fetchTrashed: includes deleted scratch items") {
    let (store, _) = try makeStore()
    let note = scratchItem("note")
    let todo = newItem(type: .todo, typeData: .todo(ActionableData()))
    for i in [note, todo] { try store.create(i) }
    try store.softDelete(id: note.id)
    try store.softDelete(id: todo.id)
    return try store.fetchTrashed().count == 2
}

// Today never surfaces scratch, which is the whole point of the allowlists.
check("fetchTodaySidebar: never includes scratch") {
    let (store, _) = try makeStore()
    try store.create(scratchItem("note"))
    return try store.fetchTodaySidebar(asOf: CivilDate.today).isEmpty
}

// Nor does the CLI's active-actionable list.
check("fetchAllActionable: never includes scratch") {
    let (store, _) = try makeStore()
    try store.create(scratchItem("note"))
    return try store.fetchAllActionable().isEmpty
}

// Nor the icebox, which scratch can never enter.
check("fetchIceboxed: never includes scratch") {
    let (store, _) = try makeStore()
    let note = scratchItem("note")
    try store.create(note)
    try store.setIceboxed(id: note.id, true)
    return try store.fetchIceboxed().isEmpty
}

// Clipboard: a scratch entry copies verbatim — no fence, no heading, no
// metadata — because the point is pasting the parked value somewhere else.
check("clipboard: scratch copies as its raw body") {
    let note = scratchItem("https://example.com/thing?a=1")
    return note.clipboardMarkdown() == "https://example.com/thing?a=1"
}

// Clipboard: an actionable item keeps its framed form, so scratch's special
// case did not leak.
check("clipboard: an actionable item keeps its fenced form") {
    let todo = newItem(
        type: .todo, typeData: .todo(ActionableData()), title: "Buy milk")
    let out = todo.clipboardMarkdown()
    return out.hasPrefix("---\n# Buy milk") && out.hasSuffix("---")
}

// MARK: - Scratch conversion

// The note shape both the composer and `scratch.add` write, so the two writers
// cannot drift.
check("ScratchItem.make: body-only disposition, blank refused") {
    guard let note = ScratchItem.make(
        text: "  remember the milk\nand the eggs  ", workspaceID: "local")
    else { return false }
    let shapeOK = note.type == "scratch"
        && note.body == "remember the milk\nand the eggs"
        && note.title == "remember the milk"
        && note.typeData == .scratch(ScratchData())
    let bareOK = note.source == "manual" && note.externalID == nil
        && note.scheduledOn == nil && note.iceboxedAt == nil
        && note.resolvedAt == nil && note.position == nil
    return shapeOK && bareOK
        && ScratchItem.make(text: "   \n ", workspaceID: "local") == nil
}

// Convert rewrites the SAME row: id and created_at survive, type and payload
// swap, the composed title/body/link land. Both timestamps are read back from
// the database so the comparison is text-vs-text, the way the upsert checks do
// it — an in-memory Date carries precision the column does not.
check("convertScratch: rewrites the row in place, keeping id + created_at") {
    let (store, _) = try makeStore()
    let note = scratchItem("wire up the retry\nsecond line")
    try store.create(note)
    guard let before = try store.fetch(id: note.id) else { return false }
    try store.convertScratch(
        id: note.id, to: .todo, title: "  Wire up the retry  ",
        body: "the plan", externalURL: "https://example.com/doc")
    guard let after = try store.fetch(id: note.id) else { return false }
    guard case .todo(let d) = after.typeData else { return false }
    // Split into sub-expressions: one long `&&` chain over many optionals
    // overwhelms the Swift type-checker.
    let identityOK = after.id == before.id
        && after.createdAt == before.createdAt && after.source == "manual"
    let swapped = after.type == "todo" && d.externalURL == "https://example.com/doc"
    let composed = after.title == "Wire up the retry" && after.body == "the plan"
    let leftTheFeed = try scratchCount(store, resolved: false) == 0
    let joinedTheWork = try store.fetchAllActionable().contains { $0.id == note.id }
    return identityOK && swapped && composed && leftTheFeed && joinedTheWork
}

// A nil body carries the note's text over rather than clearing it — the body IS
// the note, so a convert that composes only a title never discards what it was
// composed from. An explicit blank still clears, and a blank title leaves the
// derived one standing (`title` is NOT NULL).
check("convertScratch: nil body keeps the text; blank body/title fall back") {
    let (store, _) = try makeStore()
    let keep = scratchItem("keep this text")
    let clear = scratchItem("drop this text")
    try store.create(keep)
    try store.create(clear)
    try store.convertScratch(
        id: keep.id, to: .reminder, title: "Keep", body: nil, externalURL: nil)
    try store.convertScratch(
        id: clear.id, to: .reminder, title: "   ", body: "   ", externalURL: nil)
    guard let k = try store.fetch(id: keep.id),
          let c = try store.fetch(id: clear.id) else { return false }
    return k.body == "keep this text" && k.title == "Keep"
        && c.body == nil && c.title == "drop this text"
}

// A completed note promotes as completed work. Resolution is state the row
// carries, not something a conversion is entitled to reverse.
check("convertScratch: a completed note stays resolved") {
    let (store, _) = try makeStore()
    let note = scratchItem("did this already")
    try store.create(note)
    try store.resolve(id: note.id)
    try store.convertScratch(
        id: note.id, to: .todo, title: "Did this already", body: nil,
        externalURL: nil)
    guard let after = try store.fetch(id: note.id) else { return false }
    let offToday = try store.fetchActionable(asOf: CivilDate.today)
        .contains { $0.id == note.id } == false
    return after.resolvedAt != nil && after.type == "todo" && offToday
}

// A stale iceboxed stamp is cleared. `setIceboxed` is type-agnostic, so a note
// can carry one; left in place it would route the converted item into the
// Icebox instead of onto Today, invisibly.
check("convertScratch: clears a stale iceboxed stamp") {
    let (store, _) = try makeStore()
    let note = scratchItem("a thought")
    try store.create(note)
    try store.setIceboxed(id: note.id, true)
    try store.convertScratch(
        id: note.id, to: .todo, title: "A thought", body: nil, externalURL: nil)
    guard let after = try store.fetch(id: note.id) else { return false }
    let onToday = try store.fetchActionable(asOf: CivilDate.today)
        .contains { $0.id == note.id }
    return after.iceboxedAt == nil && onToday
}

// Only a note is convertible — an actionable row is `reclassify`'s job — and the
// refusal leaves it untouched, since every guard runs before the first write.
check("convertScratch: refuses a non-scratch row") {
    let (store, _) = try makeStore()
    let todo = newItem(
        type: .todo, typeData: .todo(ActionableData(listName: "later")),
        title: "already work")
    try store.create(todo)
    var refused = false
    do {
        try store.convertScratch(
            id: todo.id, to: .reminder, title: "nope", body: nil, externalURL: nil)
    } catch ItemStoreError.convertRequiresScratch {
        refused = true
    }
    guard let after = try store.fetch(id: todo.id) else { return false }
    return refused && after.type == "todo" && after.title == "already work"
}

// A trashed note stays trashed. Recovering it and promoting it are two
// decisions, so the Trash is not a back door onto Today.
check("convertScratch: refuses a trashed note") {
    let (store, _) = try makeStore()
    let note = scratchItem("parked then discarded")
    try store.create(note)
    try store.softDelete(id: note.id)
    var refused = false
    do {
        try store.convertScratch(
            id: note.id, to: .todo, title: "Revive", body: nil, externalURL: nil)
    } catch ItemStoreError.convertTrashedRefused {
        refused = true
    }
    guard let after = try store.fetch(id: note.id) else { return false }
    return refused && after.type == "scratch" && after.deletedAt != nil
}

// The target must be actionable: calendar is read-only and scratch is where the
// row already sits, so neither is a destination.
check("convertScratch: refuses a non-actionable target") {
    let (store, _) = try makeStore()
    let note = scratchItem("a thought")
    try store.create(note)
    var refusals = 0
    for target in [ItemType.calendar, .scratch] {
        do {
            try store.convertScratch(
                id: note.id, to: target, title: "T", body: nil, externalURL: nil)
        } catch ItemStoreError.convertRequiresActionableTarget {
            refusals += 1
        }
    }
    guard let after = try store.fetch(id: note.id) else { return false }
    let stillInFeed = try scratchCount(store, resolved: false) == 1
    return refusals == 2 && after.type == "scratch" && stillInFeed
}

// Catalog: scratch documents its own `l` leader. The existing l-leader check is
// satisfied by the Lists section alone, so it would pass with these rows
// missing — which is the drift that matters, since the two surfaces bind the
// same three letters to different verbs.
// The existing l-leader sweep is satisfied by the Lists section alone, so it
// would pass with these rows missing — which is the drift that matters, since the
// two surfaces share the letters and only `l l` means the same thing on both.
check("catalog: scratch documents its l-leader chords") {
    let scratchKeys = Set(KeystrokeCatalog.all.compactMap { e -> String? in
        guard e.section == .scratch, case .literal(let k) = e.binding
        else { return nil }
        return k
    })
    return ["l t", "l r", "l e", "l l"].allSatisfy { scratchKeys.contains($0) }
        // `* a` narrows to the focused row's group now that the feed is grouped,
        // so it must not still promise the whole feed.
        && KeystrokeCatalog.all.contains {
            $0.section == .scratch && $0.binding == .literal("* a")
                && $0.label == "Select all in group"
        }
}

// MARK: - Selection invariants

// X refuses a focus that no visible row carries. This is the invariant whose
// absence produced a selection nothing could display: the count climbed, no
// checkbox ticked, and the batch actions — all scoped to visible rows — then
// found nothing to act on.
checkMainActor("selection: X refuses a focus no visible row carries") {
    let selection = ActionableSelection()
    selection.focus("gone")
    selection.toggleSelectedFocused(in: ["a", "b"])
    return selection.selectedIDs.isEmpty && !selection.hasSelection
}

checkMainActor("selection: X toggles a visible focused row both ways") {
    let selection = ActionableSelection()
    selection.focus("b")
    selection.toggleSelectedFocused(in: ["a", "b"])
    guard selection.selectedIDs == ["b"] else { return false }
    selection.toggleSelectedFocused(in: ["a", "b"])
    return selection.selectedIDs.isEmpty
}

checkMainActor("selection: X with no focus at all is a no-op") {
    let selection = ActionableSelection()
    selection.toggleSelectedFocused(in: ["a", "b"])
    return selection.selectedIDs.isEmpty
}

// ensureFocus fills a gap without ever moving a focus the user placed, which is
// what makes it safe to call on arrival and on every query change.
checkMainActor("selection: ensureFocus seats the first row when focus is absent") {
    let selection = ActionableSelection()
    selection.ensureFocus(in: ["a", "b"])
    return selection.focusedItemID == "a"
}

checkMainActor("selection: ensureFocus leaves a live focus alone") {
    let selection = ActionableSelection()
    selection.focus("b")
    selection.ensureFocus(in: ["a", "b"])
    return selection.focusedItemID == "b"
}

checkMainActor("selection: ensureFocus reseats a focus the visible set dropped") {
    let selection = ActionableSelection()
    selection.focus("hidden")
    selection.ensureFocus(in: ["a", "b"])
    return selection.focusedItemID == "a"
}

checkMainActor("selection: ensureFocus clears focus when nothing is visible") {
    let selection = ActionableSelection()
    selection.focus("a")
    selection.ensureFocus(in: [])
    return selection.focusedItemID == nil
}

// reconcile still prunes a stale selection, and now reseats focus through the
// same rule rather than its own copy of it.
checkMainActor("selection: reconcile prunes departed rows and reseats focus") {
    let selection = ActionableSelection()
    selection.selectAll(in: ["a", "b", "c"])
    selection.focus("c")
    selection.reconcile(visible: ["a", "b"], present: ["a", "b"])
    return selection.selectedIDs == ["a", "b"] && selection.focusedItemID == "a"
}

print(failures == 0
    ? "\n✅ all smoke checks passed"
    : "\n❌ \(failures) smoke check(s) failed")
exit(failures == 0 ? 0 : 1)
