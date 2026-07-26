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

    private init() {
        // Restore the persisted tab; fall back to the first case if absent or
        // unrecognized (e.g. a tab that no longer exists). Resolution goes
        // through `fromPersisted` so the terminal tab's pre-rename value still
        // maps onto it.
        let restored = MainTab.fromPersisted(
            WindowStatePersistence.shared.loadSelectedMainTab()
        )
        selectedTab = restored ?? MainTab.allCases.first ?? .terminal
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
