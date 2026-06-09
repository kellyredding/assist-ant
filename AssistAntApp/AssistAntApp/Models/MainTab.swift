import Foundation

/// The tabs shown in the main window's title-bar tab strip. Each case is one
/// right-pane view (everything outside the today sidebar). Adding a tab is:
/// add a case, give it a title + SF Symbol icon below, and add its view to
/// the ZStack switch in ContentView.
enum MainTab: String, CaseIterable {
    case agent

    var title: String {
        switch self {
        case .agent: return "Agent"
        }
    }

    var icon: String {
        switch self {
        case .agent: return "apple.terminal"
        }
    }
}
