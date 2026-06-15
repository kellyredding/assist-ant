import Foundation

/// Drives user-initiated Linear re-syncs from the UI: asks the embedded agent
/// to run the sync skill and tracks an in-flight flag for the refresh
/// affordances. The flag clears when actionable items next change (the sync
/// committed) or after a timeout (agent busy / nothing landed).
final class LinearSyncCoordinator: ObservableObject {
    static let shared = LinearSyncCoordinator()

    @Published private(set) var isSyncing = false

    /// Ceiling so the indicator can't spin forever if no change ever lands.
    private static let timeout: TimeInterval = 90
    private var timeoutWork: DispatchWorkItem?

    private init() {
        NotificationCenter.default.addObserver(
            forName: .actionableItemsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.finish()
        }
    }

    /// Ask the embedded agent to re-sync the to-dos by sending it a sync prompt
    /// the persona interprets (the Linear sync direction). No-ops (and shows no
    /// spinner) when the agent isn't running, since the prompt would go nowhere.
    func requestSync() {
        guard AgentSessionController.shared.state == .running else {
            NSLog("LinearSyncCoordinator: agent not running — sync request ignored")
            return
        }
        AgentSessionController.shared.send(text: "Sync my Linear issues", asPaste: true)
        AgentSessionController.shared.submit()
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
