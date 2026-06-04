import Foundation
import Galactic

/// Codable settings record persisted to disk. Bumps `version` whenever the
/// schema gains a non-backwards-compatible field; SettingsManager uses the
/// version to decide whether to migrate or to start from defaults.
///
/// The shape grows as features land — fields with `decodeIfPresent`
/// fallback so existing prefs.json files keep working across schema
/// additions.
///
/// `schedule`, `muteWhileMicInUse`, and `isMuted` are app-level (not
/// announcement-owned) because they are the shared inputs to the audio
/// gate: the weekly window that says "when I'm working", the global
/// "don't make noise during calls" toggle, and the open-ended manual
/// mute. Both time announcements and the desk timer read them. `schedule`
/// and `muteWhileMicInUse` used to live nested under `announcement` and
/// are migrated up transparently — see `init(from:)`.
struct AppSettings: Codable, Equatable {
    var version: Int
    var themePreference: ThemePreference
    var timeFormat: TimeFormat
    var announcement: AnnouncementSettings
    var schedule: WeeklySchedule          // shared by announcements + desk
    var muteWhileMicInUse: Bool           // global: silences all audio
    var isMuted: Bool                     // global manual mute (open-ended)
    var desk: DeskSettings                // standing-desk sit/stand timer

    // Embedded agent terminal settings — the three knobs the Agent
    // settings tab exposes. The terminal color theme is intentionally NOT
    // stored or user-editable: it is supplied by the GalacticConfiguration
    // conformance as a hardcoded default.
    var terminalFontFamily: String        // monospaced family for the agent terminal
    var defaultTerminalFontSize: CGFloat   // point size for the agent terminal
    var terminalScrollbackLines: Int       // scrollback buffer depth in lines

    static let current = AppSettings(
        version: 1,
        themePreference: .system,
        timeFormat: .twelveHour,
        announcement: .defaults,
        schedule: .workdayDefault,
        muteWhileMicInUse: true,
        isMuted: false,
        desk: .defaults,
        terminalFontFamily: "SF Mono",
        defaultTerminalFontSize: 13.0,
        terminalScrollbackLines: 10_000
    )

    // Constraints for the Agent settings tab fields (the tab clamps typed
    // values into these ranges).
    static let terminalFontSizeRange: ClosedRange<CGFloat> = 10...24
    static let terminalFontSizeStep: CGFloat = 1
    static let terminalScrollbackRange: ClosedRange<Int> = 500...100_000

    /// Estimated memory for a given scrollback line count. Assumes a
    /// 200-column terminal at 16 bytes/cell (3,200 bytes/line), rounded up
    /// to whole MB.
    static func estimatedScrollbackMemory(lines: Int) -> String {
        let megabytes = ceil(Double(lines) * 3_200.0 / 1_000_000.0)
        return "~\(Int(megabytes)) MB"
    }

    // Custom decoder so prefs.json files saved before a field existed (or
    // written by a future version that drops fields) decode cleanly to
    // defaults instead of failing the whole decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(
            Int.self, forKey: .version
        ) ?? AppSettings.current.version
        self.themePreference = try container.decodeIfPresent(
            ThemePreference.self, forKey: .themePreference
        ) ?? AppSettings.current.themePreference
        self.timeFormat = try container.decodeIfPresent(
            TimeFormat.self, forKey: .timeFormat
        ) ?? AppSettings.current.timeFormat
        self.announcement = try container.decodeIfPresent(
            AnnouncementSettings.self, forKey: .announcement
        ) ?? AppSettings.current.announcement

        // One-time migration: `schedule` and `muteWhileMicInUse` used to
        // live nested under `announcement`. Read them from there as a
        // fallback so an existing prefs.json keeps the user's customized
        // schedule and toggle when they move to the top level. Reading the
        // `announcement` key a second time as a legacy container is safe
        // with JSONDecoder (keyed containers re-read).
        var legacySchedule: WeeklySchedule?
        var legacyMuteMic: Bool?
        if let legacy = try? container.nestedContainer(
            keyedBy: LegacyAnnouncementKeys.self, forKey: .announcement
        ) {
            legacySchedule = try? legacy.decodeIfPresent(
                WeeklySchedule.self, forKey: .schedule
            )
            legacyMuteMic = try? legacy.decodeIfPresent(
                Bool.self, forKey: .muteWhileMicInUse
            )
        }

        self.schedule = try container.decodeIfPresent(
            WeeklySchedule.self, forKey: .schedule
        ) ?? legacySchedule ?? AppSettings.current.schedule
        self.muteWhileMicInUse = try container.decodeIfPresent(
            Bool.self, forKey: .muteWhileMicInUse
        ) ?? legacyMuteMic ?? AppSettings.current.muteWhileMicInUse
        self.isMuted = try container.decodeIfPresent(
            Bool.self, forKey: .isMuted
        ) ?? AppSettings.current.isMuted
        self.desk = try container.decodeIfPresent(
            DeskSettings.self, forKey: .desk
        ) ?? AppSettings.current.desk

        self.terminalFontFamily = try container.decodeIfPresent(
            String.self, forKey: .terminalFontFamily
        ) ?? AppSettings.current.terminalFontFamily
        self.defaultTerminalFontSize = try container.decodeIfPresent(
            CGFloat.self, forKey: .defaultTerminalFontSize
        ) ?? AppSettings.current.defaultTerminalFontSize
        self.terminalScrollbackLines = try container.decodeIfPresent(
            Int.self, forKey: .terminalScrollbackLines
        ) ?? AppSettings.current.terminalScrollbackLines
    }

    init(
        version: Int,
        themePreference: ThemePreference,
        timeFormat: TimeFormat,
        announcement: AnnouncementSettings,
        schedule: WeeklySchedule,
        muteWhileMicInUse: Bool,
        isMuted: Bool,
        desk: DeskSettings,
        terminalFontFamily: String,
        defaultTerminalFontSize: CGFloat,
        terminalScrollbackLines: Int
    ) {
        self.version = version
        self.themePreference = themePreference
        self.timeFormat = timeFormat
        self.announcement = announcement
        self.schedule = schedule
        self.muteWhileMicInUse = muteWhileMicInUse
        self.isMuted = isMuted
        self.desk = desk
        self.terminalFontFamily = terminalFontFamily
        self.defaultTerminalFontSize = defaultTerminalFontSize
        self.terminalScrollbackLines = terminalScrollbackLines
    }

    /// Whether audible announcements (time or desk) may play right now:
    /// inside the schedule window, not snoozed by the mute timer, not away
    /// from the desk, and not suppressed by the mic. Visual is never
    /// subject to this — only audio passes through this gate.
    func audioGateOpen(
        at now: Date,
        micInUse: Bool,
        calendar: Calendar = .current
    ) -> Bool {
        if muteWhileMicInUse, micInUse { return false }
        if desk.isAwayActive { return false }
        if isMuted { return false }
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        guard let wi = c.weekday, let weekday = Weekday(rawValue: wi),
              let h = c.hour, let m = c.minute else { return false }
        return schedule.isActive(
            at: TimeOfDay(hour: h, minute: m), weekday: weekday
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case themePreference
        case timeFormat
        case announcement
        case schedule
        case muteWhileMicInUse
        case isMuted
        case desk
        case terminalFontFamily
        case defaultTerminalFontSize
        case terminalScrollbackLines
    }

    /// Legacy keys for reading schedule + muteWhileMicInUse out of the
    /// old nested `announcement` block during one-time migration.
    private enum LegacyAnnouncementKeys: String, CodingKey {
        case schedule
        case muteWhileMicInUse
    }
}

/// Conformance to Galactic's configuration seam. `terminalFontFamily`,
/// `defaultTerminalFontSize`, and `terminalScrollbackLines` are stored
/// properties whose names match the protocol verbatim. The color theme is
/// not a user setting here — it is pinned to the default theme so the
/// embedded agent terminal renders identically to a default-theme session.
extension AppSettings: GalacticConfiguration {
    /// The default terminal color theme id. Resolved by
    /// `TerminalColorTheme.theme(named:)` inside Galactic; an unrecognized
    /// name falls back to the same default, so this is safe even across
    /// Galactic theme-catalog changes.
    var terminalColorThemeName: String { "galaxy-default" }
}
