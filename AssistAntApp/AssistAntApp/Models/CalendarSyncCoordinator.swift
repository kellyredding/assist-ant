import Foundation

extension Notification.Name {
    /// Posted by the app's calendar-sync handler right after it applies a sync
    /// (upsert + prune) to the item store. Windowed views that don't observe
    /// the store live (the Calendar agenda) refresh on this, and the
    /// sync-in-flight indicators clear on it. The today sidebar doesn't need
    /// it — it's built on a live store observation and updates on its own.
    static let calendarItemsDidChange = Notification.Name("calendarItemsDidChange")
}

/// Drives user-initiated calendar re-syncs from the UI: asks the embedded
/// agent to run the sync skill and tracks an in-flight flag for the refresh
/// affordances. The flag clears when calendar items next change (the sync
/// committed) or after a timeout (agent busy / nothing landed).
final class CalendarSyncCoordinator: ObservableObject {
    static let shared = CalendarSyncCoordinator()

    @Published private(set) var isSyncing = false

    /// Ceiling so the indicator can't spin forever if no change ever lands.
    private static let timeout: TimeInterval = 90
    private var timeoutWork: DispatchWorkItem?

    private init() {
        NotificationCenter.default.addObserver(
            forName: .calendarItemsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.finish()
        }
    }

    /// Ask the embedded agent to re-sync the calendar by invoking the sync
    /// skill. No-ops (and shows no spinner) when the agent isn't running, since
    /// the command would go nowhere.
    func requestSync() {
        guard AgentSessionController.shared.state == .running else {
            NSLog("CalendarSyncCoordinator: agent not running — sync request ignored")
            return
        }
        AgentSessionController.shared.sendCommand("/assist-ant-sync-calendar-items")
        isSyncing = true
        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finish() }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.timeout, execute: work)
    }

    private func finish() {
        timeoutWork?.cancel()
        timeoutWork = nil
        if isSyncing { isSyncing = false }
    }
}
