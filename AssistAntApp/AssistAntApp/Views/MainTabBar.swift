import SwiftUI

/// The main window's tab strip, hosted as a trailing title-bar accessory.
/// One button per MainTab; the selected tab gets a subtle filled background.
/// Adapted from Galaxy's in-content tabPicker
/// (~/projects/kellyredding/galaxy/GalaxyApp/GalaxyApp/ContentView.swift).
struct MainTabBar: View {
    @ObservedObject private var navigator = MainTabNavigator.shared

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MainTab.allCases, id: \.self) { tab in
                Button {
                    // Any tab click dismisses an open reader — including a click
                    // on the current tab, which leaves the selection unchanged
                    // (so the tab-change observer wouldn't fire on its own).
                    ItemViewerModel.shared.close()
                    navigator.selectedTab = tab
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.icon)
                        Text(tab.title)
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(navigator.selectedTab == tab
                                  ? Color.primary.opacity(0.1)
                                  : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(navigator.selectedTab == tab ? .primary : .secondary)
            }
        }
    }
}
