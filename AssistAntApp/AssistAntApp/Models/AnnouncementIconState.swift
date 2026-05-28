import Foundation

/// Visual state of the `AnnounceStatusButton` (and the corresponding
/// muted status row in `ClockView`). Computed from settings + current
/// time; reflects whether announcements are off, set up but currently
/// quiet, currently inside an active schedule window, or temporarily
/// muted.
///
/// `muted` takes precedence over `active`/`scheduled` whenever mute
/// is in effect — the schedule may say "yes, fire" but mute overrides
/// until expiry. `disabled` is checked first (master Enable off).
enum AnnouncementIconState: Equatable {
    case disabled       // master enable off
    case scheduled      // on with at least one output, not muted,
                        // currently outside today's window — OR on but
                        // with no output selected (nothing would ever
                        // fire, so it's inert regardless of schedule)
    case active         // on, not muted, currently inside today's window
    case muted          // on, mute window in effect right now

    /// SF Symbol name for this state. Glyph progression encodes
    /// "intensity": no waves (quiet) → 3 waves (active), with the
    /// slash variants reserved for the two off states.
    var sfSymbol: String {
        switch self {
        case .disabled:  return "speaker.slash"
        case .scheduled: return "speaker.fill"
        case .active:    return "speaker.wave.3.fill"
        case .muted:     return "speaker.slash.fill"
        }
    }

    /// Whether the state represents an "off-ish" condition (no
    /// announcements firing right now). `disabled` and `muted` are
    /// both quiescent; `scheduled` and `active` are both "on" states.
    /// The visual treatment is independent — muted is rendered in
    /// system orange for state-change emphasis, not dim secondary.
    var isQuiescent: Bool {
        switch self {
        case .disabled, .muted: return true
        case .scheduled, .active: return false
        }
    }
}

extension AnnouncementSettings {
    /// Pure decision: what is the icon state at `now` given these
    /// settings? Side-effect-free so it can be exercised without
    /// touching the system clock. Returns `.scheduled` as the
    /// fallback when calendar component extraction fails (defense
    /// in depth — the input Date should always yield valid
    /// components in practice).
    func iconState(
        at now: Date,
        calendar: Calendar = .current
    ) -> AnnouncementIconState {
        guard enabled else { return .disabled }

        // No output selected → nothing will ever fire, so the icon is
        // inert (shown as .scheduled: speaker.fill, click routes to
        // Settings). Checked before mute because a mute window is
        // meaningless when there's nothing to suppress — rendering
        // .muted (orange) here would falsely imply something is being
        // silenced.
        guard playSound || speakTime else { return .scheduled }

        if let until = muteUntil, now < until {
            return .muted
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
