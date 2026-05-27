import SwiftUI

/// Root view inside the preferences modal. Horizontal icon tab strip at the
/// top, divider, then the selected tab's content view below.
///
/// Mirrors the layout pattern from Galaxy's SettingsView
/// (~/projects/kellyredding/galaxy/GalaxyApp/GalaxyApp/Views/SettingsView.swift).
struct SettingsView: View {
    @ObservedObject var settingsManager = SettingsManager.shared
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            // Icon tab bar
            HStack(spacing: 0) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    SettingsTabButton(
                        tab: tab,
                        isSelected: selectedTab == tab
                    ) {
                        selectedTab = tab
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Divider()

            // Tab content
            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsTab(settingsManager: settingsManager)
                case .time:
                    TimeSettingsTab(settingsManager: settingsManager)
                }
            }
        }
        .frame(width: 420, height: 320)
    }
}
