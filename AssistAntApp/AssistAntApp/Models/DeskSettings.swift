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
    /// User stepped away from the desk; the timer is paused until they
    /// return (not time-bound). Takes precedence over counting/nudge.
    case away
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
///
/// `isAway` is the one thing that *pauses* the otherwise-never-pausing
/// timer: while set, the timer doesn't count or nudge — posture tracking
/// is meaningless when you're not at the desk. It is not time-bound: you
/// stay away until you return, at which point `DeskService` clears it and
/// starts a fresh sit interval.
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

    /// When true, the user has stepped away and the timer is paused
    /// ("away from desk") until they return. Not time-bound.
    var isAway: Bool

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
        isAway: false,
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
    ///
    /// `away` outranks counting/nudge. On return `DeskService` clears it
    /// and resets `positionStartedAt`, so a stale pre-away value never
    /// surfaces a nudge.
    func timerPhase(at now: Date) -> DeskTimerPhase {
        // Away is a global concept — it outranks the timer and applies even
        // when the timer is disabled, so it is checked before `enabled`.
        if isAway {
            return .away
        }
        guard enabled else { return .inactive }
        guard let startedAt = positionStartedAt else { return .inactive }
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

    /// True while the away state is in effect. Away is global — it applies
    /// whether or not the desk timer is enabled — so the audio gate and
    /// icon state read this to mute time announcements and surface the away
    /// reason, the same way mic-in-use does.
    var isAwayActive: Bool {
        isAway
    }
}

// MARK: - Backward-compatible decoding

extension DeskSettings {
    private enum CodingKeys: String, CodingKey {
        case enabled, sitMinutes, standMinutes, currentPosition,
             positionStartedAt, isAway, playSound, sound, speakAlert,
             voiceIdentifier
    }

    /// Custom decoder so an existing prefs.json `desk` block written
    /// before a field existed still decodes — the new keys fall back to
    /// `.defaults` rather than throwing (which would fail the whole
    /// `AppSettings` decode and reset all settings). Declared in an
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
        self.isAway = try c.decodeIfPresent(
            Bool.self, forKey: .isAway
        ) ?? d.isAway
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
