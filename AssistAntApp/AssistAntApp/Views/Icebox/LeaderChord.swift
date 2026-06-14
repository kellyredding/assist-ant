import AppKit

/// A leader-with-timeout key sequence: arm a leader key, and the next key
/// pressed within `timeout` is its second key. Shared by the list-chord
/// controller (`ActionableListChords`) and the item reader (`ItemViewerModel`)
/// so the arm / expire mechanics live in one place; each host owns its own
/// key→action mapping.
@MainActor
final class LeaderChord {
    /// The currently-armed leader, or nil when idle.
    private(set) var pending: Character?

    private var timer: DispatchWorkItem?
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 1.0) { self.timeout = timeout }

    /// Arm `leader`; it expires on its own after `timeout` if no key follows.
    func arm(_ leader: Character) {
        pending = leader
        timer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pending = nil }
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    /// Return the armed leader (if any) and clear it — call on the next key to
    /// decide whether it completes a chord.
    func take() -> Character? {
        defer { clear() }
        return pending
    }

    func clear() {
        pending = nil
        timer?.cancel()
        timer = nil
    }
}
