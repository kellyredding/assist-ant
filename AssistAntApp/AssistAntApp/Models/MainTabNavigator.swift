import Foundation

/// Shared selection state for the main window's title-bar tab strip. Observed
/// by `ContentView` (to switch the right-pane view) and `MainTabBar` (to
/// render selection). The selection is persisted via `WindowStatePersistence`
/// — per-machine window/view state, restored on relaunch.
final class MainTabNavigator: ObservableObject {
    static let shared = MainTabNavigator()

    @Published var selectedTab: MainTab {
        didSet {
            guard selectedTab != oldValue else { return }
            WindowStatePersistence.shared.saveSelectedMainTab(selectedTab.rawValue)
        }
    }

    /// A calendar item id the Calendar tab should open in its event reader,
    /// set by a Today-sidebar tap (alongside flipping `selectedTab` to
    /// `.calendar`). `CalendarPaneView` consumes it — opens the reader, then
    /// clears it back to nil. Transient (not persisted). Calendar items only;
    /// reminders never set this.
    @Published var pendingEventShow: String?

    private init() {
        // Restore the persisted tab; fall back to the first case if absent or
        // unrecognized (e.g. a tab that no longer exists).
        let restored = WindowStatePersistence.shared.loadSelectedMainTab()
            .flatMap(MainTab.init(rawValue:))
        selectedTab = restored ?? MainTab.allCases.first ?? .agent
    }

    /// Previous tab, stopping at the first (no wrap) — matches Galaxy.
    func switchToPreviousTab() {
        let all = MainTab.allCases
        guard let i = all.firstIndex(of: selectedTab), i > all.startIndex
        else { return }
        selectedTab = all[all.index(before: i)]
    }

    /// Next tab, stopping at the last (no wrap) — matches Galaxy.
    func switchToNextTab() {
        let all = MainTab.allCases
        guard let i = all.firstIndex(of: selectedTab) else { return }
        let next = all.index(after: i)
        guard next < all.endIndex else { return }
        selectedTab = all[next]
    }
}
