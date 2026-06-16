import Foundation
import GRDB

/// One entry in the task run log (Tier-0, fire-and-forget): a record that a
/// task was *sent* to the agent (or *skipped* because the agent was down). No
/// turn-end correlation — the log only attests delivery.
///
/// `taskID` is nullable and `taskName` is a denormalized snapshot, so a run
/// survives deletion of its task (no FK; see the migration). The log renders
/// reverse-chronological by `firedAt`.
struct TaskRun: Codable, Equatable, FetchableRecord, PersistableRecord {
    var id: String                 // UUIDv7, client-minted
    var taskID: String?            // nullable: row survives task deletion
    var taskName: String           // denormalized snapshot of the task name
    var trigger: String            // "recurring" | "one_shot" | "manual" | "run_now"
    var firedAt: Date
    var status: String             // Tier-0: "sent" | "skipped"
    var detail: String?            // e.g. "agent not running"

    static let databaseTableName = "task_runs"

    enum CodingKeys: String, CodingKey {
        case id
        case taskID = "task_id"
        case taskName = "task_name"
        case trigger
        case firedAt = "fired_at"
        case status
        case detail
    }
}

extension TaskRun {
    /// Build a Tier-0 run record: `sent` when the agent was running and the
    /// prompt was submitted, `skipped` (with a reason) when it was down. Pure so
    /// it's testable without the session controller / AppKit.
    static func make(
        taskID: String?, name: String, trigger: String,
        agentRunning: Bool, at: Date = Date()
    ) -> TaskRun {
        TaskRun(
            id: UUIDv7.generate(), taskID: taskID, taskName: name,
            trigger: trigger, firedAt: at,
            status: agentRunning ? "sent" : "skipped",
            detail: agentRunning ? nil : "agent not running")
    }
}
