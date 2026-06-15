import Foundation
import Combine

/// Drives the Tasks tab. Snapshot/refresh like `IceboxModel`: the list
/// re-fetches on activation and on an explicit `refresh()`, never live.
///
/// The tab is read-only apart from two zero-form row verbs — an enabled toggle
/// and delete — which write through the store and mutate the in-memory snapshot
/// in place so the row updates without a re-fetch. Task *authoring* (create /
/// edit) is agentic (the `assist-ant task` CLI), not a UI form; after a
/// CLI-driven write the authoring layer calls `refresh()` on the main queue to
/// re-sync this table.
@MainActor
final class TasksModel: ObservableObject {
    static let shared = TasksModel()

    @Published private(set) var tasks: [AgentTask] = []
    @Published private(set) var runs: [TaskRun] = []
    @Published private(set) var isLoading = false

    private let store: TasksStore
    private var hasActivatedOnce = false

    init(store: TasksStore = .shared) {
        self.store = store
    }

    /// Called when the Tasks tab becomes active: load once with a spinner, then
    /// refresh on later activations.
    func activate() {
        if !hasActivatedOnce {
            hasActivatedOnce = true
            load(spinner: true)
        } else {
            refresh()
        }
    }

    /// Re-read tasks + runs from the store. The seam Phase 5's `task.*` handlers
    /// poke after a CLI-driven write so the read-only table stays current.
    func refresh() { load(spinner: false) }

    // MARK: - Row verbs (write through the store + snapshot in place)

    @discardableResult
    func setEnabled(_ task: AgentTask, _ enabled: Bool) -> Bool {
        do {
            try store.setEnabled(id: task.id, enabled)
            if let i = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[i].enabled = enabled
            }
            return true
        } catch {
            NSLog("TasksModel: setEnabled failed for \(task.id): \(error)")
            return false
        }
    }

    func delete(_ task: AgentTask) {
        do {
            try store.delete(id: task.id)
            tasks.removeAll { $0.id == task.id }
        } catch {
            NSLog("TasksModel: delete failed for \(task.id): \(error)")
        }
    }

    private func load(spinner: Bool) {
        if spinner { isLoading = true }
        do {
            tasks = try store.allTasks()
            runs = try store.recentRuns(limit: 100)
        } catch {
            NSLog("TasksModel: load failed: \(error)")
        }
        isLoading = false
    }
}
