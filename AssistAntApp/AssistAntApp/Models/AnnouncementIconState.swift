import Foundation

/// Visual state of the `AnnounceStatusButton` (and the corresponding
/// muted status row in `ClockView`). Computed from settings + current
/// time + live mic state; reflects whether announcements are off, set
/// up but currently quiet, currently inside an active schedule window,
/// or temporarily muted — and if muted, why.
///
/// Precedence (highest first): `disabled`, then `mutedByAway`, then
/// `mutedByMic`, then `mutedManually`, then the schedule window
/// (`active` / `scheduled`). Away outranks the call and the manual mute —
/// stepping away is the most deliberate silence signal — and mic-mute
/// outranks the manual mute so a live call shows the mic reason while a
/// manual mute is also in effect, each reverting as it clears.
enum AnnouncementIconState: Equatable {
    case disabled       // master enable off
    case scheduled      // on with at least one output, not muted,
                        // currently outside today's window — OR on but
                        // with no output selected (nothing would ever
                        // fire, so it's inert regardless of schedule)
    case active         // on, not muted, currently inside today's window
    case mutedManually  // on, user muted manually (open-ended) until unmute
    case mutedByMic     // on, mic in use and "mute while mic in use" on
    case mutedByAway    // on, stepped away from the desk (away window)

    /// SF Symbol name for this state. Glyph progression encodes
    /// "intensity": no waves (quiet) → 3 waves (active), with the
    /// slash variants reserved for the off/muted states. The mute
    /// reasons all share the slashed-fill glyph — the reason is
    /// conveyed by the status text, not the icon.
    var sfSymbol: String {
        switch self {
        case .disabled:     return "speaker.slash"
        case .scheduled:    return "speaker.fill"
        case .active:       return "speaker.wave.3.fill"
        case .mutedManually: return "speaker.slash.fill"
        case .mutedByMic:   return "speaker.slash.fill"
        case .mutedByAway:  return "speaker.slash.fill"
        }
    }

    /// Whether this is one of the muted states. They render in system
    /// orange and show a status row under the clock.
    var isMuted: Bool {
        switch self {
        case .mutedManually, .mutedByMic, .mutedByAway: return true
        case .disabled, .scheduled, .active: return false
        }
    }
}

extension AppSettings {
    /// Pure decision: what is the icon state at `now`, given these
    /// settings and the live `micInUse` flag? Side-effect-free so it
    /// can be exercised without touching the system clock or the audio
    /// hardware. Returns `.scheduled` as the fallback when calendar
    /// component extraction fails (defense in depth — the input Date
    /// should always yield valid components in practice).
    ///
    /// Lives on `AppSettings` (not `AnnouncementSettings`) because it
    /// reads the top-level shared `schedule`, `muteWhileMicInUse`, and
    /// `isMuted` alongside both features' sub-fields. "Disabled" spans
    /// both: it's shown only when neither time announcements nor the desk
    /// timer can emit audio.
    func iconState(
        at now: Date,
        micInUse: Bool,
        calendar: Calendar = .current
    ) -> AnnouncementIconState {
        // Audio-capable per feature: master enable on AND at least one
        // output selected. Disabled only when neither feature can speak.
        let timeCapable = announcement.enabled
            && (announcement.playSound || announcement.speakTime)
        let deskCapable = desk.enabled
            && (desk.playSound || desk.speakAlert)
        guard timeCapable || deskCapable else { return .disabled }

        // Away outranks every other mute reason: stepping away is the
        // most deliberate "silence everything" signal, so it wins the
        // display even over a live call or a running timed mute.
        if desk.isAwayActive {
            return .mutedByAway
        }

        // Mic-mute outranks the timed mute: a live call wins the
        // display even if a timed mute is also running underneath.
        if muteWhileMicInUse, micInUse {
            return .mutedByMic
        }

        if isMuted {
            return .mutedManually
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

        // A disabled master switch reads exactly like being outside the
        // schedule window: nothing will fire, so show the quiet
        // plain-speaker (`.scheduled`) glyph rather than the active waves —
        // and `.scheduled` is already clickable (opens Settings), so the
        // handling matches outside-schedule too.
        let timeOfDay = TimeOfDay(hour: hour, minute: minute)
        let withinWindow = announcementsEnabled
            && schedule.isActive(at: timeOfDay, weekday: weekday)
        return withinWindow ? .active : .scheduled
    }
}
