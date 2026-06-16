import Foundation
import GRDB

/// A task: a named prompt plus a trigger the heartbeat/runner deliver to the
/// embedded agent. The persona interprets the prompt; this record only stores
/// *what* to send and *when*. Authoring is agentic (the `assist-ant task` CLI),
/// so there is no UI create/edit form — the Tasks tab observes these rows.
///
/// Named `AgentTask`, not `Task`, to avoid shadowing Swift concurrency's
/// `Task`; the backing table is still `tasks`.
///
/// Trigger shape, by `triggerType`:
/// - `recurring`: `cadenceKind` is `interval` (uses `intervalSeconds`) or
///   `daily` (uses `dailyTime`, `"HH:MM"` local). Either kind may carry a
///   `weekdays` mask; `interval` may also carry a `windowStart`/`windowEnd`
///   pair that anchors the interval inside a daily time window.
/// - `one_shot`: `runAt` is the fire instant, or nil to fire on the next tick.
/// - `manual`: `manualKey` names a built-in trigger (e.g. the Today refreshes);
///   manual tasks fire only on demand.
///
/// `lastRunAt` is the field the recurring due-eval reads for dedup/coalescing.
/// Column names are pinned via explicit snake_case `CodingKeys` (GRDB derives
/// column names from the coding keys), matching `Item`.
struct AgentTask: Codable, Equatable, FetchableRecord, PersistableRecord {
    var id: String                 // UUIDv7, client-minted
    var name: String               // user-facing label
    var triggerType: String        // "recurring" | "one_shot" | "manual"
    var cadenceKind: String?       // recurring: "interval" | "daily"
    var intervalSeconds: Int?      // recurring + interval (e.g. 900, 3600)
    var dailyTime: String?         // recurring + daily, "HH:MM" local
    var weekdays: String?          // recurring: ISO-weekday mask "1,2,…7"; nil = every day
    var windowStart: String?       // recurring + interval: window open "HH:MM" local
    var windowEnd: String?         // recurring + interval: window close "HH:MM" local
    var runAt: Date?               // one_shot fire instant; nil = next tick
    var manualKey: String?         // manual: built-in trigger key
    var prompt: String             // the text sent to the agent
    var enabled: Bool
    var lastRunAt: Date?           // drives recurring dedup/coalescing
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "tasks"

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case triggerType = "trigger_type"
        case cadenceKind = "cadence_kind"
        case intervalSeconds = "interval_seconds"
        case dailyTime = "daily_time"
        case weekdays
        case windowStart = "window_start"
        case windowEnd = "window_end"
        case runAt = "run_at"
        case manualKey = "manual_key"
        case prompt
        case enabled
        case lastRunAt = "last_run_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

extension AgentTask {
    /// Built-in manual-trigger keys backing the Today sync glyphs. Seeded as
    /// tasks; the runner routes these to their sync coordinators.
    static let calendarRefreshKey = "today_calendar_refresh"
    static let todoRefreshKey = "today_todo_refresh"

    /// The allowed ISO weekdays (1=Mon … 7=Sun) parsed from `weekdays`. A nil,
    /// empty, or all-junk mask resolves to the full week, so a recurring task
    /// with no weekday filter still fires every day. The due-eval (Phase 4) and
    /// the row summary both read this, so the "unset = every day" rule lives in
    /// one place.
    var weekdaySet: Set<Int> {
        guard let weekdays else { return Set(1...7) }
        let parsed = Set(
            weekdays.split(separator: ",").compactMap {
                Int($0.trimmingCharacters(in: .whitespaces))
            }.filter { (1...7).contains($0) }
        )
        return parsed.isEmpty ? Set(1...7) : parsed
    }
}
