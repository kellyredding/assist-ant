import Foundation

/// Codable settings record persisted to disk. Bumps `version` whenever the
/// schema gains a non-backwards-compatible field; SettingsManager uses the
/// version to decide whether to migrate or to start from defaults.
///
/// The shape grows as features land — fields with `decodeIfPresent`
/// fallback so existing prefs.json files keep working across schema
/// additions.
struct AppSettings: Codable, Equatable {
    var version: Int
    var themePreference: ThemePreference
    var timeFormat: TimeFormat
    var announcement: AnnouncementSettings

    static let current = AppSettings(
        version: 1,
        themePreference: .system,
        timeFormat: .twelveHour,
        announcement: .defaults
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
    }

    init(
        version: Int,
        themePreference: ThemePreference,
        timeFormat: TimeFormat,
        announcement: AnnouncementSettings
    ) {
        self.version = version
        self.themePreference = themePreference
        self.timeFormat = timeFormat
        self.announcement = announcement
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case themePreference
        case timeFormat
        case announcement
    }
}
