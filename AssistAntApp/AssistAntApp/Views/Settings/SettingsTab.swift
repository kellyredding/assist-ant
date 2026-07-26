import Foundation

/// Settings tabs shown in the preferences modal. Each case is one tab in
/// the horizontal icon strip at the top of SettingsView. Adding a new tab
/// is three steps: add a case, give it a title + SF Symbol icon below, and
/// extend SettingsView's switch.
enum SettingsTab: String, CaseIterable {
    case general
    case workspace
    case announcements
    case time
    case calendar
    case desk
    case terminal
    case popovers

    var title: String {
        switch self {
        case .general: return "General"
        case .workspace: return "Workspace"
        case .announcements: return "Announce"
        case .time: return "Time"
        case .calendar: return "Calendar"
        case .desk: return "Desk"
        case .terminal: return "Terminal"
        case .popovers: return "Popovers"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .workspace: return "macwindow"
        case .announcements: return "speaker.wave.3.fill"
        case .time: return "clock"
        case .calendar: return "calendar"
        case .desk: return "chair.fill"
        case .terminal: return "apple.terminal"
        case .popovers: return "text.viewfinder"
        }
    }
}
