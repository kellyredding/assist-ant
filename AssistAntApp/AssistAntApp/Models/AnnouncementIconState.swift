import Foundation

/// Visual state of the `AnnounceStatusButton` (and the corresponding
/// muted status row in `ClockView`). Computed from settings + current
/// time + live mic state; reflects whether announcements are off, set
/// up but currently quiet, currently inside an active schedule window,
/// or temporarily muted — and if muted, why.
///
/// Precedence (highest first): `disabled`, then inert-no-output
/// (`scheduled`), then `mutedByMic`, then `mutedByTimer`, then the
/// schedule window (`active` / `scheduled`). Mic-mute outranks the
/// timed mute so that picking up a call while a timed mute is running
/// shows the mic reason, reverting to the timer reason when the mic
/// frees.
enum AnnouncementIconState: Equatable {
    case disabled       // master enable off
    case scheduled      // on with at least one output, not muted,
                        // currently outside today's window — OR on but
                        // with no output selected (nothing would ever
                        // fire, so it's inert regardless of schedule)
    case active         // on, not muted, currently inside today's window
    case mutedByTimer   // on, ad-hoc timed mute (muteUntil) in effect
    case mutedByMic     // on, mic in use and "mute while mic in use" on

    /// SF Symbol name for this state. Glyph progression encodes
    /// "intensity": no waves (quiet) → 3 waves (active), with the
    /// slash variants reserved for the off/muted states. Both mute
    /// reasons share the slashed-fill glyph — the reason is conveyed
    /// by the status text, not the icon.
    var sfSymbol: String {
        switch self {
        case .disabled:     return "speaker.slash"
        case .scheduled:    return "speaker.fill"
        case .active:       return "speaker.wave.3.fill"
        case .mutedByTimer: return "speaker.slash.fill"
        case .mutedByMic:   return "speaker.slash.fill"
        }
    }

    /// Whether this is one of the two muted states. Both render in
    /// system orange and show a status row under the clock.
    var isMuted: Bool {
        switch self {
        case .mutedByTimer, .mutedByMic: return true
        case .disabled, .scheduled, .active: return false
        }
    }
}

extension AnnouncementSettings {
    /// Pure decision: what is the icon state at `now`, given these
    /// settings and the live `micInUse` flag? Side-effect-free so it
    /// can be exercised without touching the system clock or the audio
    /// hardware. Returns `.scheduled` as the fallback when calendar
    /// component extraction fails (defense in depth — the input Date
    /// should always yield valid components in practice).
    func iconState(
        at now: Date,
        micInUse: Bool,
        calendar: Calendar = .current
    ) -> AnnouncementIconState {
        guard enabled else { return .disabled }

        // No output selected → nothing will ever fire, so the icon is
        // inert (shown as .scheduled: speaker.fill, click routes to
        // Settings). Checked before mute because a mute is meaningless
        // when there's nothing to suppress.
        guard playSound || speakTime else { return .scheduled }

        // Mic-mute outranks the timed mute: a live call wins the
        // display even if a timed mute is also running underneath.
        if muteWhileMicInUse, micInUse {
            return .mutedByMic
        }

        if let until = muteUntil, now < until {
            return .mutedByTimer
        }

        let components = calendar.dateComponents(
            [.weekday, .hour, .minute], from: now
        )
        guard
            let weekdayInt = components.weekday,
            let weekday = Weekday(rawValue: weekdayInt),
            let hour = components.hour,
            let minute = components.minute
        else { return .scheduled }

        let timeOfDay = TimeOfDay(hour: hour, minute: minute)
        return schedule.isActive(at: timeOfDay, weekday: weekday)
            ? .active
            : .scheduled
    }
}
