import Foundation

/// Settings tabs shown in the preferences modal. Each case is one tab in the
/// horizontal icon strip at the top of SettingsView. Adding a new tab is
/// three steps: add a case, give it a title + SF Symbol icon below, and
/// extend SettingsView's switch.
///
/// Mirrors Galaxy's SettingsTab pattern
/// (~/projects/kellyredding/galaxy/GalaxyApp/GalaxyApp/Views/SettingsView.swift).
enum SettingsTab: String, CaseIterable {
    case general

    var title: String {
        switch self {
        case .general: return "General"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        }
    }
}
