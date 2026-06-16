import Foundation

/// Delivers a task's prompt to the embedded agent and records a Tier-0 run.
/// The single place a task fires and gets logged — the run-now ▶ and the two
/// Today sync glyphs route through here, and the Phase-4 heartbeat will reuse
/// `runBatch`.
///
/// Delivery never interrupts: a prompt sent while the agent is mid-turn rides
/// Claude Code's native FIFO queue. Built-in sync tasks (matched by
/// `manual_key`) delegate to their coordinator, which owns the prompt and the
/// commit/timeout spinner; every other task delivers its stored prompt. Lives
/// in `Models/` (not `Models/Items/`) so the smoke tool — which can't see the
/// session controller — doesn't compile it.
@MainActor
enum TaskRunner {
    /// Fire one task and log the run. `trigger` is the run's recorded origin
    /// (`run_now`, `manual`, and — from Phase 4 — `recurring` / `one_shot`).
    static func run(_ task: AgentTask, trigger: String) {
        deliver(for: task)
        record(taskID: task.id, name: task.name, trigger: trigger, prompt: task.prompt)
    }

    /// Fire several tasks back-to-back, each fully submitted before the next so
    /// prompts don't collide in the input buffer. (Wired by the Phase-4
    /// heartbeat; unused by the Phase-3 single-task manual triggers.)
    static func runBatch(_ tasks: [AgentTask], trigger: String) {
        for task in tasks { run(task, trigger: trigger) }
    }

    /// The Today Calendar glyph: run the seeded built-in (so the log ties to its
    /// row), falling back to driving the coordinator directly if it was deleted.
    static func runCalendarGlyph() {
        runBuiltin(key: AgentTask.calendarRefreshKey, fallbackName: "Calendar sync")
    }

    /// The Today To-do glyph: same shape for the Linear sync.
    static func runLinearGlyph() {
        runBuiltin(key: AgentTask.todoRefreshKey, fallbackName: "Linear sync")
    }

    // MARK: - Delivery

    private static func runBuiltin(key: String, fallbackName: String) {
        let task = try? TasksStore.shared.task(manualKey: key)
        deliverBuiltin(key: key)
        record(taskID: task?.id, name: task?.name ?? fallbackName, trigger: "manual",
               prompt: task?.prompt)
    }

    private static func deliver(for task: AgentTask) {
        switch task.manualKey {
        case AgentTask.calendarRefreshKey, AgentTask.todoRefreshKey:
            deliverBuiltin(key: task.manualKey ?? "")
        default:
            guard AgentSessionController.shared.state == .running else { return }
            AgentSessionController.shared.send(text: task.prompt, asPaste: true)
            AgentSessionController.shared.submit()
        }
    }

    /// Route a built-in sync key to its coordinator (which self-guards on the
    /// agent running and owns the spinner/timeout).
    private static func deliverBuiltin(key: String) {
        switch key {
        case AgentTask.calendarRefreshKey:
            CalendarSyncCoordinator.shared.requestSync()
        case AgentTask.todoRefreshKey:
            LinearSyncCoordinator.shared.requestSync()
        default:
            break
        }
    }

    // MARK: - Logging

    private static func record(taskID: String?, name: String, trigger: String, prompt: String?) {
        let running = AgentSessionController.shared.state == .running
        let run = TaskRun.make(
            taskID: taskID, name: name, trigger: trigger,
            agentRunning: running, prompt: prompt)
        do {
            try TasksStore.shared.recordRun(run)
        } catch {
            NSLog("TaskRunner: recordRun failed: \(error)")
        }
        TasksModel.shared.refresh()
    }
}
