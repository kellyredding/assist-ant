import SwiftUI

/// Root view inside the preferences modal. Horizontal icon tab strip at the
/// top, divider, then the selected tab's content view below.
///
/// Mirrors the layout pattern from Galaxy's SettingsView
/// (~/projects/kellyredding/galaxy/GalaxyApp/GalaxyApp/Views/SettingsView.swift).
struct SettingsView: View {
    @ObservedObject var settingsManager = SettingsManager.shared

    /// Tab selection is owned by the shared `SettingsNavigator` rather
    /// than a local `@State` so that `PreferencesWindowController.
    /// showPreferences(initialTab:)` can switch the active tab before
    /// any open — including the second-and-later opens that wouldn't
    /// re-run a `@State` initializer.
    @ObservedObject private var navigator = SettingsNavigator.shared

    var body: some View {
        VStack(spacing: 0) {
            // Icon tab bar
            HStack(spacing: 0) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    SettingsTabButton(
                        tab: tab,
                        isSelected: navigator.selectedTab == tab
                    ) {
                        navigator.selectedTab = tab
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Divider()

            // Tab content lays out at its natural height. NSHostingController
            // observes the SwiftUI view's intrinsic size and resizes its
            // window to match — General is short, Time grows as the
            // schedule editor expands. No explicit max-height; the view
            // is exactly as tall as it needs to be.
            Group {
                switch navigator.selectedTab {
                case .general:
                    GeneralSettingsTab(settingsManager: settingsManager)
                case .announcements:
                    AnnouncementsSettingsTab(settingsManager: settingsManager)
                case .time:
                    TimeSettingsTab(settingsManager: settingsManager)
                case .desk:
                    DeskSettingsTab(settingsManager: settingsManager)
                case .agent:
                    AgentSettingsTab(settingsManager: settingsManager)
                }
            }
        }
        // Width is fixed because picker widths and the tab strip are
        // designed around 480pt. Height stays unconstrained so the
        // controller's auto-sizing has room to grow.
        .frame(width: 480)
    }
}
