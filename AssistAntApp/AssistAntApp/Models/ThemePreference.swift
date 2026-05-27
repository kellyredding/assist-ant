import Foundation

/// User-selectable theme. Window controllers translate this into an
/// NSAppearance via a helper local to each controller; `.system` returns
/// `nil` which makes the window inherit the OS appearance.
///
/// Adapted from Galaxy's ThemePreference declaration
/// (~/projects/kellyredding/galaxy/GalaxyApp/GalaxyApp/Models/SettingsManager.swift).
enum ThemePreference: String, Codable, CaseIterable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: return "Match system"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var iconName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}
