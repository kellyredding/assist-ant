import Foundation
import GRDB

/// GRDB-backed store for the task system, alongside `GRDBItemStore` and sharing
/// the same items `DatabaseQueue`. Pure and smoke-testable (Foundation + GRDB,
/// no AppKit).
///
/// The full write surface (`create` / `update` / `delete` / `setEnabled`) ships
/// in this phase even though the read-only Tasks tab only toggles and deletes:
/// the agentic authoring layer (the `assist-ant task` CLI's `task.*` handlers)
/// calls `create` / `update` here directly. GRDB serializes writes on the
/// queue, so those off-main writes are safe.
final class TasksStore {
    static let shared = TasksStore()

    private let dbQueue: DatabaseQueue

    private init() {
        self.dbQueue = ItemsDatabase.shared.dbQueue
    }

    /// Test seam: inject a migrated (e.g. in-memory) queue.
    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Tasks

    /// All tasks in creation order (UUIDv7 id approximates it; `created_at`
    /// pins it precisely).
    func allTasks() throws -> [AgentTask] {
        try dbQueue.read { db in
            try AgentTask.order(sql: "created_at, id").fetchAll(db)
        }
    }

    func task(id: String) throws -> AgentTask? {
        try dbQueue.read { db in try AgentTask.fetchOne(db, key: id) }
    }

    /// Insert a new task, stamping created/updated locally.
    func create(_ task: AgentTask) throws {
        var task = task
        let now = Date()
        task.createdAt = now
        task.updatedAt = now
        try dbQueue.write { db in try task.insert(db) }
    }

    /// Replace an existing task in place, refreshing `updated_at`.
    func update(_ task: AgentTask) throws {
        var task = task
        task.updatedAt = Date()
        try dbQueue.write { db in try task.update(db) }
    }

    func delete(id: String) throws {
        _ = try dbQueue.write { db in try AgentTask.deleteOne(db, key: id) }
    }

    func setEnabled(id: String, _ enabled: Bool) throws {
        try dbQueue.write { db in
            guard var task = try AgentTask.fetchOne(db, key: id) else { return }
            task.enabled = enabled
            task.updatedAt = Date()
            try task.update(db)
        }
    }

    /// Stamp a recurring task's `last_run_at` — the field the due-eval reads for
    /// dedup/coalescing. The runner/heartbeat (a later phase) calls this; it
    /// lives here so the read path and the write path share one store.
    func markRan(id: String, at instant: Date = Date()) throws {
        try dbQueue.write { db in
            guard var task = try AgentTask.fetchOne(db, key: id) else { return }
            task.lastRunAt = instant
            task.updatedAt = Date()
            try task.update(db)
        }
    }

    // MARK: - Run log

    func recordRun(_ run: TaskRun) throws {
        try dbQueue.write { db in try run.insert(db) }
    }

    /// The most recent runs, newest first. `fired_at` is a GRDB Date → TEXT
    /// "YYYY-MM-DD HH:MM:SS.SSS", so DESC sorts reverse-chronologically.
    func recentRuns(limit: Int = 100) throws -> [TaskRun] {
        try dbQueue.read { db in
            try TaskRun
                .order(sql: "fired_at DESC, id DESC")
                .limit(limit)
                .fetchAll(db)
        }
    }
}
