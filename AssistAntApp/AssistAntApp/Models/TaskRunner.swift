import Foundation

/// Delivers a task's prompt to the embedded agent and records a Tier-0 run.
/// The single place a task fires and gets logged — the run-now ▶ and the two
/// Today sync glyphs route through here, and the Phase-4 heartbeat will reuse
/// `runBatch`.
///
/// Delivery never interrupts: a prompt sent while the agent is mid-turn rides
/// Claude Code's native FIFO queue. Every task — including the Today-glyph
/// ones — delivers its own stored prompt; a glyph just fires all the enabled
/// tasks that share its key. Lives in `Models/` (not `Models/Items/`) so the
/// smoke tool — which can't see the session controller — doesn't compile it.
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

    /// The Today Calendar glyph: fire every enabled calendar-keyed Today task.
    static func runCalendarGlyph() { runTodayKey(AgentTask.calendarRefreshKey) }

    /// The Today To-do glyph: same for the to-do-keyed Today tasks.
    static func runLinearGlyph() { runTodayKey(AgentTask.todoRefreshKey) }

    /// Fire every enabled `today` task bound to `key` — the glyph's tasks —
    /// each as its own agent message and run-log row. If nothing matches (all
    /// deleted or disabled), nothing runs.
    static func runTodayKey(_ key: String) {
        let tasks = (try? TasksStore.shared.tasks(todayKey: key))?.filter(\.enabled) ?? []
        runBatch(tasks, trigger: "today")
    }

    // MARK: - Delivery

    /// Prepended to every delivered task prompt so the embedded agent hands the
    /// work to a background subagent instead of running it in the main thread —
    /// automated tasks must not block the session or flood its context, since
    /// the user's own requests often run concurrently. Centralizing it here is
    /// the de-dupe: individual task prompts describe only their work and never
    /// repeat the "use a background subagent" boilerplate, and the policy is one
    /// edit. Only delivery is wrapped — `record` still logs the raw prompt.
    private static let backgroundDirective = """
        Automated AssistAnt task. Run the whole thing in a background subagent so \
        this session stays free for other work: launch it with the Task tool using \
        run_in_background, don't do the work in the main thread or block on it, and \
        relay only a brief result when it finishes. The task:
        """

    /// The stored prompt with the background directive prepended, as delivered.
    private static func backgroundWrapped(_ prompt: String) -> String {
        "\(backgroundDirective)\n\n\(prompt)"
    }

    private static func deliver(for task: AgentTask) {
        guard AgentSessionController.shared.state == .running else { return }
        // Enqueue rather than paste+CR inline: the controller submits each prompt
        // on its own (paste → delay → CR), so a multi-line prompt's Return isn't
        // swallowed into the bracketed paste, and batched fires don't collide.
        AgentSessionController.shared.enqueuePrompt(backgroundWrapped(task.prompt))
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
