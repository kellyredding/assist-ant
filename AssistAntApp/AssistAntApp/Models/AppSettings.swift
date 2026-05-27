import Foundation

/// Codable settings record persisted to disk. Bumps `version` whenever the
/// schema gains a non-backwards-compatible field; SettingsManager uses the
/// version to decide whether to migrate or to start from defaults.
///
/// The shape is intentionally small at first — future fields land here as
/// settings UI grows (quiet hours, voice selection, standing-desk cadence,
/// etc.).
struct AppSettings: Codable, Equatable {
    var version: Int
    var themePreference: ThemePreference
    var timeFormat: TimeFormat

    static let current = AppSettings(
        version: 1,
        themePreference: .system,
        timeFormat: .twelveHour
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
    }

    init(
        version: Int,
        themePreference: ThemePreference,
        timeFormat: TimeFormat
    ) {
        self.version = version
        self.themePreference = themePreference
        self.timeFormat = timeFormat
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case themePreference
        case timeFormat
    }
}
