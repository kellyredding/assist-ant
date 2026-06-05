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
    title: String = "t"
) -> Item {
    Item(
        id: UUIDv7.generate(), tenantID: "local", type: type.rawValue,
        title: title, body: nil, source: source, externalID: externalID,
        typeData: typeData, iceboxedAt: nil, deletedAt: nil,
        createdAt: Date(), updatedAt: Date(), serverUpdatedAt: nil, pending: false
    )
}

// 1. Round-trip every item type through the store (persists + reads back).
check("round-trip all item types") {
    let (store, _) = try makeStore()
    let items = [
        newItem(type: .calendar, typeData: .calendar(CalendarData(allDay: true))),
        newItem(type: .todo, typeData: .todo(TodoData(
            listName: "errands",
            scheduledOn: CivilDate(year: 2026, month: 6, day: 6)))),
        newItem(type: .reminder, typeData: .reminder(ReminderData(
            startingOn: CivilDate(year: 2026, month: 6, day: 7)))),
        newItem(type: .explore, typeData: .explore(ExploreData(
            externalURL: "https://example.com",
            addedOn: CivilDate(year: 2026, month: 6, day: 5)))),
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
    let keep = newItem(type: .todo, typeData: .todo(TodoData()), title: "keep")
    let del = newItem(type: .todo, typeData: .todo(TodoData()), title: "del")
    let ice = newItem(type: .todo, typeData: .todo(TodoData()), title: "ice")
    try store.create(keep)
    try store.create(del)
    try store.create(ice)
    try store.softDelete(id: del.id)
    try store.setIceboxed(id: ice.id, true)
    let active = try store.fetchActive(type: nil)
    return active.count == 1 && active.first?.id == keep.id
}

// 5. Unique identity index rejects duplicate (tenant, source, external_id);
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
    try store.create(newItem(type: .todo, typeData: .todo(TodoData())))
    try store.create(newItem(type: .todo, typeData: .todo(TodoData())))
    let manualCount = try store.fetchActive(type: .todo).count
    return rejected && manualCount == 2
}

// 6. VACUUM INTO produces a consistent, restorable snapshot.
check("VACUUM INTO snapshot is restorable") {
    let (store, queue) = try makeStore()
    for _ in 0..<5 {
        try store.create(newItem(type: .todo, typeData: .todo(TodoData())))
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

print(failures == 0
    ? "\n✅ all smoke checks passed"
    : "\n❌ \(failures) smoke check(s) failed")
exit(failures == 0 ? 0 : 1)
