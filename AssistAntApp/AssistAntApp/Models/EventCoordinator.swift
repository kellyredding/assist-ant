import Foundation

/// Routes decoded envelopes from SocketListener to subscribers.
/// Maintains a known-events allowlist so unknown event names are
/// dropped (logged) rather than crashing or silently propagating.
final class EventCoordinator {
    /// Free-form event names the app understands. Unknown events
    /// are silently dropped. Adding a new event = add it here +
    /// extend whatever handler in AppDelegate dispatches on it.
    /// The CLI side does not need to know this set.
    static let knownEvents: Set<String> = [
        "ping",
        "calendar_item.upsert",
        "calendar_item.prune",
    ]

    var onEvent: ((EventEnvelope) -> Void)?

    func route(_ envelope: EventEnvelope) {
        guard Self.knownEvents.contains(envelope.event) else {
            NSLog("EventCoordinator: dropping unknown event '\(envelope.event)'")
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(envelope)
        }
    }
}
