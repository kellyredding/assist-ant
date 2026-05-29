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
/// prefs.json via AppSettings.
///
/// Audio is independent of time announcements (Option A): the desk has
/// its own `playSound` + `speakAlert` toggles, its own `sound` (default
/// `.funk`, distinct from the time chime's `.glass`), and its own voice,
/// so a posture nudge is audibly distinct. The shared gate + serializer
/// (schedule window, snooze, mic) are applied by `DeskService` via
/// `AppSettings.audioGateOpen` and `AudioAnnouncementCoordinator`.
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

    // Audio outputs (independent of time announcements).
    var playSound: Bool
    var sound: AnnouncementSound
    var speakAlert: Bool
    var voiceIdentifier: String?

    static let defaults = DeskSettings(
        enabled: false,
        sitMinutes: 20,
        standMinutes: 8,
        currentPosition: .sitting,
        positionStartedAt: nil,
        playSound: true,
        sound: .funk,
        speakAlert: true,
        voiceIdentifier: nil
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

// MARK: - Backward-compatible decoding

extension DeskSettings {
    private enum CodingKeys: String, CodingKey {
        case enabled, sitMinutes, standMinutes, currentPosition,
             positionStartedAt, playSound, sound, speakAlert, voiceIdentifier
    }

    /// Custom decoder so an existing prefs.json `desk` block written
    /// before the audio fields existed still decodes — the new keys fall
    /// back to `.defaults` rather than throwing (which would fail the
    /// whole `AppSettings` decode and reset all settings). Declared in an
    /// extension so the synthesized memberwise initializer survives intact.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DeskSettings.defaults
        self.enabled = try c.decodeIfPresent(
            Bool.self, forKey: .enabled
        ) ?? d.enabled
        self.sitMinutes = try c.decodeIfPresent(
            Int.self, forKey: .sitMinutes
        ) ?? d.sitMinutes
        self.standMinutes = try c.decodeIfPresent(
            Int.self, forKey: .standMinutes
        ) ?? d.standMinutes
        self.currentPosition = try c.decodeIfPresent(
            DeskPosition.self, forKey: .currentPosition
        ) ?? d.currentPosition
        self.positionStartedAt = try c.decodeIfPresent(
            Date.self, forKey: .positionStartedAt
        ) ?? d.positionStartedAt
        self.playSound = try c.decodeIfPresent(
            Bool.self, forKey: .playSound
        ) ?? d.playSound
        self.sound = try c.decodeIfPresent(
            AnnouncementSound.self, forKey: .sound
        ) ?? d.sound
        self.speakAlert = try c.decodeIfPresent(
            Bool.self, forKey: .speakAlert
        ) ?? d.speakAlert
        self.voiceIdentifier = try c.decodeIfPresent(
            String.self, forKey: .voiceIdentifier
        ) ?? d.voiceIdentifier
    }
}
