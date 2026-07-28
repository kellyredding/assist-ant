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
/// `announcementHours`, `muteWhileMicInUse`, and `isMuted` are app-level
/// (not announcement-owned) because they are the shared inputs to the audio
/// gate: the weekly window that says "when I'm working", the global
/// "don't make noise during calls" toggle, and the open-ended manual
/// mute. Both time announcements and the desk timer read them.
/// `announcementHours` and `muteWhileMicInUse` used to live nested under
/// `announcement` and are migrated up transparently — see `init(from:)`.
struct AppSettings: Codable, Equatable {
    var version: Int
    var themePreference: ThemePreference
    var timeFormat: TimeFormat
    var announcement: AnnouncementSettings
    var announcementHours: AnnouncementHours  // shared by announcements + desk
    var muteWhileMicInUse: Bool           // global: silences all audio
    var isMuted: Bool                     // global manual mute (open-ended)
    var announcementsEnabled: Bool        // master: silence all audible announcements
    var desk: DeskSettings                // standing-desk sit/stand timer
    var calendarAnnouncement: CalendarAnnouncementSettings  // upcoming-event announcements

    // Embedded agent terminal settings — the knobs the Terminal settings tab
    // exposes. The terminal color theme is intentionally NOT stored or
    // user-editable: it is supplied by the GalacticConfiguration conformance
    // as a hardcoded default.
    var terminalFontFamily: String        // monospaced family for the agent terminal
    var defaultTerminalFontSize: CGFloat   // point size for the agent terminal
    var terminalScrollbackLines: Int       // scrollback buffer depth in lines
    var terminalCursorStyle: ShellCursorStyle  // caret shape
    var terminalCursorBlink: Bool          // whether the caret blinks
    var shellDefaultHeightRatio: Double    // shell pane's share of the split

    // Quick Capture. The per-kind summon shortcuts persist through the
    // KeyboardShortcuts library (not here); this is the one capture knob the
    // library doesn't own — whether directly summoning a capture popover (any
    // kind) auto-starts Wispr hands-free dictation.
    var captureAutoArmWispr: Bool

    // Which keystrokes commit text and which insert a newline. Governs the
    // local composers directly, and the embedded session by way of Claude
    // Code's own keybindings file — see ClaudeKeybindingsWriter.
    var textEntry: TextEntryBindings

    static let current = AppSettings(
        version: 1,
        themePreference: .system,
        timeFormat: .twelveHour,
        announcement: .defaults,
        announcementHours: .workdayDefault,
        muteWhileMicInUse: true,
        isMuted: false,
        announcementsEnabled: true,
        desk: .defaults,
        calendarAnnouncement: .defaults,
        terminalFontFamily: "SF Mono",
        defaultTerminalFontSize: 13.0,
        terminalScrollbackLines: 10_000,
        terminalCursorStyle: .block,
        terminalCursorBlink: false,
        shellDefaultHeightRatio: 0.5,
        captureAutoArmWispr: true,
        textEntry: .default
    )

    // Constraints for the Terminal settings tab fields (the tab clamps typed
    // values into these ranges).
    static let terminalFontSizeRange: ClosedRange<CGFloat> = 10...24
    static let terminalFontSizeStep: CGFloat = 1
    static let terminalScrollbackRange: ClosedRange<Int> = 500...100_000

    /// Bounds on the shell pane's share of the Terminal tab. The same window
    /// the divider drag enforces, so a configured default can never disagree
    /// with what a drag allows.
    static let shellDefaultHeightRatioRange: ClosedRange<Double> = 0.30...0.70
    static let shellDefaultHeightRatioStep: Double = 0.01

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

        // One-time migration: `announcementHours` and `muteWhileMicInUse`
        // used to live nested under `announcement`. Read them from there as a
        // fallback so an existing prefs.json keeps the user's customized
        // hours and toggle when they move to the top level. Reading the
        // `announcement` key a second time as a legacy container is safe
        // with JSONDecoder (keyed containers re-read).
        var legacyAnnouncementHours: AnnouncementHours?
        var legacyMuteMic: Bool?
        if let legacy = try? container.nestedContainer(
            keyedBy: LegacyAnnouncementKeys.self, forKey: .announcement
        ) {
            legacyAnnouncementHours = try? legacy.decodeIfPresent(
                AnnouncementHours.self, forKey: .schedule
            )
            legacyMuteMic = try? legacy.decodeIfPresent(
                Bool.self, forKey: .muteWhileMicInUse
            )
        }

        self.announcementHours = try container.decodeIfPresent(
            AnnouncementHours.self, forKey: .announcementHours
        ) ?? legacyAnnouncementHours ?? AppSettings.current.announcementHours
        self.muteWhileMicInUse = try container.decodeIfPresent(
            Bool.self, forKey: .muteWhileMicInUse
        ) ?? legacyMuteMic ?? AppSettings.current.muteWhileMicInUse
        self.isMuted = try container.decodeIfPresent(
            Bool.self, forKey: .isMuted
        ) ?? AppSettings.current.isMuted
        self.announcementsEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .announcementsEnabled
        ) ?? AppSettings.current.announcementsEnabled
        self.desk = try container.decodeIfPresent(
            DeskSettings.self, forKey: .desk
        ) ?? AppSettings.current.desk
        self.calendarAnnouncement = try container.decodeIfPresent(
            CalendarAnnouncementSettings.self, forKey: .calendarAnnouncement
        ) ?? AppSettings.current.calendarAnnouncement

        self.terminalFontFamily = try container.decodeIfPresent(
            String.self, forKey: .terminalFontFamily
        ) ?? AppSettings.current.terminalFontFamily
        self.defaultTerminalFontSize = try container.decodeIfPresent(
            CGFloat.self, forKey: .defaultTerminalFontSize
        ) ?? AppSettings.current.defaultTerminalFontSize
        self.terminalScrollbackLines = try container.decodeIfPresent(
            Int.self, forKey: .terminalScrollbackLines
        ) ?? AppSettings.current.terminalScrollbackLines
        self.terminalCursorStyle = try container.decodeIfPresent(
            ShellCursorStyle.self, forKey: .terminalCursorStyle
        ) ?? AppSettings.current.terminalCursorStyle
        self.terminalCursorBlink = try container.decodeIfPresent(
            Bool.self, forKey: .terminalCursorBlink
        ) ?? AppSettings.current.terminalCursorBlink
        self.shellDefaultHeightRatio = try container.decodeIfPresent(
            Double.self, forKey: .shellDefaultHeightRatio
        ) ?? AppSettings.current.shellDefaultHeightRatio
        // Migrate the former Ask-scoped key: this toggle was
        // `captureAutoArmWisprOnAsk` when it applied only to the Ask summon.
        // Read it as a fallback so an existing prefs.json keeps the user's
        // choice now that it governs every capture kind.
        var legacyAutoArmWispr: Bool?
        if let legacy = try? decoder.container(keyedBy: LegacyCaptureKeys.self) {
            legacyAutoArmWispr = try? legacy.decodeIfPresent(
                Bool.self, forKey: .captureAutoArmWisprOnAsk)
        }
        self.captureAutoArmWispr = try container.decodeIfPresent(
            Bool.self, forKey: .captureAutoArmWispr
        ) ?? legacyAutoArmWispr ?? AppSettings.current.captureAutoArmWispr
        // Coerced on the way in: an empty submit list would leave a composer
        // with no way to commit and no save button to fall back on, and a
        // hand-edited file can arrive that way.
        self.textEntry = (try container.decodeIfPresent(
            TextEntryBindings.self, forKey: .textEntry
        ) ?? AppSettings.current.textEntry).coercingEmptyLists()
    }

    init(
        version: Int,
        themePreference: ThemePreference,
        timeFormat: TimeFormat,
        announcement: AnnouncementSettings,
        announcementHours: AnnouncementHours,
        muteWhileMicInUse: Bool,
        isMuted: Bool,
        announcementsEnabled: Bool,
        desk: DeskSettings,
        calendarAnnouncement: CalendarAnnouncementSettings,
        terminalFontFamily: String,
        defaultTerminalFontSize: CGFloat,
        terminalScrollbackLines: Int,
        terminalCursorStyle: ShellCursorStyle,
        terminalCursorBlink: Bool,
        shellDefaultHeightRatio: Double,
        captureAutoArmWispr: Bool,
        textEntry: TextEntryBindings
    ) {
        self.version = version
        self.themePreference = themePreference
        self.timeFormat = timeFormat
        self.announcement = announcement
        self.announcementHours = announcementHours
        self.muteWhileMicInUse = muteWhileMicInUse
        self.isMuted = isMuted
        self.announcementsEnabled = announcementsEnabled
        self.desk = desk
        self.calendarAnnouncement = calendarAnnouncement
        self.terminalFontFamily = terminalFontFamily
        self.defaultTerminalFontSize = defaultTerminalFontSize
        self.terminalScrollbackLines = terminalScrollbackLines
        self.terminalCursorStyle = terminalCursorStyle
        self.terminalCursorBlink = terminalCursorBlink
        self.shellDefaultHeightRatio = shellDefaultHeightRatio
        self.captureAutoArmWispr = captureAutoArmWispr
        self.textEntry = textEntry
    }

    /// Whether audible announcements (time or desk) may play right now:
    /// announcements globally enabled, inside the announcement-hours window,
    /// not snoozed by the mute timer, not away from the desk, and not
    /// suppressed by the mic. Visual is never subject to this — only audio
    /// passes through this gate.
    func audioGateOpen(
        at now: Date,
        micInUse: Bool,
        calendar: Calendar = .current
    ) -> Bool {
        // Master kill switch: announcements globally disabled silences all
        // audible output (and keeps desk nudges from surfacing the window).
        if !announcementsEnabled { return false }
        if muteWhileMicInUse, micInUse { return false }
        if desk.isAwayActive { return false }
        if isMuted { return false }
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        guard let wi = c.weekday, let weekday = Weekday(rawValue: wi),
              let h = c.hour, let m = c.minute else { return false }
        return announcementHours.isActive(
            at: TimeOfDay(hour: h, minute: m), weekday: weekday
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case themePreference
        case timeFormat
        case announcement
        case announcementHours = "schedule"
        case muteWhileMicInUse
        case isMuted
        case announcementsEnabled
        case desk
        case calendarAnnouncement
        case terminalFontFamily
        case defaultTerminalFontSize
        case terminalScrollbackLines
        case terminalCursorStyle
        case terminalCursorBlink
        case shellDefaultHeightRatio
        case captureAutoArmWispr
        case textEntry
    }

    /// Legacy keys for reading the announcement hours + muteWhileMicInUse out
    /// of the old nested `announcement` block during one-time migration. The
    /// hours persisted under the `schedule` key, so that raw value is pinned.
    private enum LegacyAnnouncementKeys: String, CodingKey {
        case schedule
        case muteWhileMicInUse
    }

    /// Legacy key for the Wispr auto-start toggle, read during one-time
    /// migration. It persisted under `captureAutoArmWisprOnAsk` back when the
    /// setting governed only the Ask summon.
    private enum LegacyCaptureKeys: String, CodingKey {
        case captureAutoArmWisprOnAsk
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
