import Foundation

/// The tabs shown in the main window's title-bar tab strip. Each case is one
/// right-pane view (everything outside the today sidebar). Adding a tab is:
/// add a case, give it a title + SF Symbol icon below, and add its view to
/// the ZStack switch in ContentView.
enum MainTab: String, CaseIterable {
    case terminal
    case schedule
    case tasks
    case scratch
    case icebox
    case trash

    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .schedule: return "Schedule"
        case .tasks: return "Tasks"
        case .scratch: return "Scratch"
        case .icebox: return "Icebox"
        case .trash: return "Trash"
        }
    }

    var icon: String {
        switch self {
        case .terminal: return "apple.terminal"
        case .schedule: return "calendar"
        case .tasks: return "list.bullet"
        case .scratch: return "square.and.pencil"
        case .icebox: return "snowflake"
        case .trash: return "trash"
        }
    }

    /// Resolve a persisted `selectedMainTab` raw value onto a case. The
    /// terminal tab persisted as `"agent"` before it was renamed, so that
    /// value is translated rather than dropped — decoding it as unrecognized
    /// would silently restore the wrong tab. Returns nil when the value
    /// matches no tab at all, leaving the fallback to the caller.
    static func fromPersisted(_ raw: String?) -> MainTab? {
        guard let raw else { return nil }
        if raw == "agent" { return .terminal }
        return MainTab(rawValue: raw)
    }
}
