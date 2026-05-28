import Foundation

/// Codable settings record persisted to disk. Bumps `version` whenever the
/// schema gains a non-backwards-compatible field; SettingsManager uses the
/// version to decide whether to migrate or to start from defaults.
///
/// The shape grows as features land — fields with `decodeIfPresent`
/// fallback so existing prefs.json files keep working across schema
/// additions.
///
/// `schedule` and `muteWhileMicInUse` are app-level (not announcement-
/// owned) because they are the shared inputs to the audio gate: the
/// weekly window that says "when I'm working" and the global "don't
/// make noise during calls" toggle. Time announcements read them today;
/// the desk timer reads the same two values without any further
/// restructuring. They used to live nested under `announcement` and are
/// migrated up transparently — see `init(from:)`.
struct AppSettings: Codable, Equatable {
    var version: Int
    var themePreference: ThemePreference
    var timeFormat: TimeFormat
    var announcement: AnnouncementSettings
    var schedule: WeeklySchedule          // shared by announcements + desk
    var muteWhileMicInUse: Bool           // global: silences all audio

    static let current = AppSettings(
        version: 1,
        themePreference: .system,
        timeFormat: .twelveHour,
        announcement: .defaults,
        schedule: .workdayDefault,
        muteWhileMicInUse: true
    )

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

        // One-time migration: `schedule` and `muteWhileMicInUse` used
        // to live nested under `announcement`. Read them from there as
        // a fallback so an existing prefs.json keeps the user's
        // customized schedule + toggle when they move to the top level.
        // Reading the `announcement` key a second time as a legacy
        // container is safe with JSONDecoder (keyed containers re-read).
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
    }

    init(
        version: Int,
        themePreference: ThemePreference,
        timeFormat: TimeFormat,
        announcement: AnnouncementSettings,
        schedule: WeeklySchedule,
        muteWhileMicInUse: Bool
    ) {
        self.version = version
        self.themePreference = themePreference
        self.timeFormat = timeFormat
        self.announcement = announcement
        self.schedule = schedule
        self.muteWhileMicInUse = muteWhileMicInUse
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case themePreference
        case timeFormat
        case announcement
        case schedule
        case muteWhileMicInUse
    }

    /// Legacy keys for reading schedule + muteWhileMicInUse out of the
    /// old nested `announcement` block during one-time migration.
    private enum LegacyAnnouncementKeys: String, CodingKey {
        case schedule
        case muteWhileMicInUse
    }
}
