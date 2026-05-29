import Foundation

/// The phase of the desk timer at a given moment, derived purely from
/// `DeskSettings` + now.
enum DeskTimerPhase: Equatable {
    /// Desk timer off (disabled) or not yet started — nothing shown.
    case inactive
    /// In the current position with time left before the next switch.
    case counting(remaining: TimeInterval, position: DeskPosition)
    /// The current position's interval has elapsed — switch to the
    /// opposite. `from` is the position you're being asked to leave.
    case nudge(from: DeskPosition)
}

/// Standing-desk timer settings + runtime position state. Persisted in
/// prefs.json via AppSettings. No audio outputs yet — those (a sound
/// toggle / a speech toggle + an own sound + an own voice) arrive once
/// the shared audio pipeline lands.
struct DeskSettings: Codable, Equatable {
    var enabled: Bool
    var sitMinutes: Int
    var standMinutes: Int

    /// Runtime state. `currentPosition` is the last-acknowledged
    /// position (defaults sitting). `positionStartedAt` is when the
    /// current position's interval began; nil means no active timer
    /// (e.g. disabled / never started). The nudge is derived — it's
    /// "pending" once `now - positionStartedAt >= interval`.
    var currentPosition: DeskPosition
    var positionStartedAt: Date?

    static let defaults = DeskSettings(
        enabled: false,
        sitMinutes: 20,
        standMinutes: 8,
        currentPosition: .sitting,
        positionStartedAt: nil
    )

    /// Interval length (seconds) for whichever position is current.
    func currentInterval() -> TimeInterval {
        let minutes = currentPosition == .sitting ? sitMinutes : standMinutes
        return TimeInterval(minutes * 60)
    }

    /// Pure decision: the timer phase at `now`. Side-effect-free.
    func timerPhase(at now: Date) -> DeskTimerPhase {
        guard enabled, let startedAt = positionStartedAt else {
            return .inactive
        }
        let elapsed = now.timeIntervalSince(startedAt)
        let interval = currentInterval()
        if elapsed >= interval {
            return .nudge(from: currentPosition)
        }
        return .counting(
            remaining: interval - elapsed,
            position: currentPosition
        )
    }
}
