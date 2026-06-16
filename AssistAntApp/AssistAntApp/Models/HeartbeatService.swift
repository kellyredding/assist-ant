import Foundation
import AppKit
import Combine

/// App-native heartbeat: on each minute tick (and on wake, via ClockService's
/// realign), fire every enabled recurring/one-shot task that `TaskSchedule`
/// reports due, through the shared `TaskRunner`. Persistent and session-
/// independent — survives `/clear`, sleep, and embedded-session restarts,
/// because it lives in the app, not the Claude session.
///
/// Lives in `Models/` (not `Models/Items/`): it touches `AgentSessionController`
/// and `TaskRunner` (AppKit), which the smoke tool can't see. The scheduling
/// math is the pure `TaskSchedule`, which the smoke tool *does* test.
///
/// A tick is a no-op unless the agent is `.running`: delivery never interrupts,
/// and a prompt sent to a down session is just lost, so the heartbeat waits and
/// retries (skip & retry). Because a tick runs to completion on the main actor
/// with no suspension points, the session state can't change mid-tick — the
/// up-front gate guarantees every fire is a `sent` run, so the bookkeeping below
/// only stamps/consumes things that were actually delivered.
@MainActor
final class HeartbeatService {
    static let shared = HeartbeatService()

    private var clockObserver: AnyCancellable?
    private var stateObserver: AnyCancellable?

    private init() {
        // Minute tick + wake realign — the same clock the desk/announce services
        // ride. @Published replays its current value on subscribe, so the first
        // tick lands at launch (a no-op until the agent is running).
        clockObserver = ClockService.shared.$currentTime
            .sink { [weak self] now in self?.tick(at: now) }

        // The instant the session comes up — fresh launch or mid-run restart —
        // sweep for anything overdue instead of waiting up to a minute for the
        // next clock tick. Mirrors DeskService's mic-free observer (react now).
        stateObserver = AgentSessionController.shared.$state
            .removeDuplicates()
            .filter { $0 == .running }
            .sink { [weak self] _ in self?.tick(at: Date()) }
    }

    /// Evaluate and fire. Gated on a running session. Post-fire bookkeeping —
    /// stamp recurring `last_run_at`, delete a fired one-shot — happens HERE, not
    /// in the generic runner: the run-now ▶ and Today glyphs reuse `TaskRunner`
    /// and must neither stamp nor consume.
    private func tick(at now: Date) {
        guard AgentSessionController.shared.state == .running else { return }

        let candidates = (try? TasksStore.shared.enabledScheduledTasks()) ?? []
        let due = candidates.filter { TaskSchedule.isDue($0, now: now) }
        guard !due.isEmpty else { return }

        for task in due {
            TaskRunner.run(task, trigger: task.triggerType)   // "recurring" | "one_shot"
            do {
                switch task.triggerType {
                case "recurring": try TasksStore.shared.markRan(id: task.id, at: now)
                case "one_shot":  try TasksStore.shared.delete(id: task.id)  // fires exactly once
                default: break
                }
            } catch {
                NSLog("HeartbeatService: bookkeeping failed for \(task.id): \(error)")
            }
        }
        TasksModel.shared.refresh()   // reflect deleted one-shots / new last_run_at
    }
}
