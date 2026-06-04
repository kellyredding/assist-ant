import Foundation

/// Settings tabs shown in the preferences modal. Each case is one tab in
/// the horizontal icon strip at the top of SettingsView. Adding a new tab
/// is three steps: add a case, give it a title + SF Symbol icon below, and
/// extend SettingsView's switch.
enum SettingsTab: String, CaseIterable {
    case general
    case announcements
    case time
    case desk
    case agent

    var title: String {
        switch self {
        case .general: return "General"
        case .announcements: return "Announcements"
        case .time: return "Time"
        case .desk: return "Desk"
        case .agent: return "Agent"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .announcements: return "speaker.wave.3.fill"
        case .time: return "clock"
        case .desk: return "chair.fill"
        case .agent: return "apple.terminal"
        }
    }
}
