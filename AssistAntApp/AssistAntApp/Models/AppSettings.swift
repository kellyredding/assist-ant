import Foundation

/// Codable settings record persisted to disk. Bumps `version` whenever the
/// schema gains a non-backwards-compatible field; SettingsManager uses the
/// version to decide whether to migrate or to start from defaults.
///
/// The shape is intentionally tiny at first — future fields land here as
/// settings UI grows (theme, quiet hours, voice selection, standing-desk
/// cadence, etc.).
struct AppSettings: Codable, Equatable {
    var version: Int

    static let current = AppSettings(version: 1)
}
