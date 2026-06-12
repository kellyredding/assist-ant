import AppKit
import SwiftUI

/// The Icebox tab's content: a control bar over a scrolled, grouped list of
/// iceboxed items. Snapshot model: the list re-fetches on activation + refresh
/// only. Opening a row hands the item to ItemViewerModel, which presents the
/// reader centrally (above the tab content) and owns its edit session and
/// keystroke handling — the reader is no longer hosted here.
struct IceboxPaneView: View {
    @ObservedObject private var model = IceboxModel.shared
    @ObservedObject private var navigator = MainTabNavigator.shared

    var body: some View {
        listPane
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.textBackgroundColor))
            .onAppear { if navigator.selectedTab == .icebox { model.activate() } }
            .onChange(of: navigator.selectedTab) { _, tab in
                if tab == .icebox { model.activate() }
            }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            IceboxControlBar(
                onRefresh: { model.refresh() },
                isWorking: model.isWorking
            )
            Divider()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.groups.isEmpty {
            VStack { Spacer(); ProgressView().scaleEffect(0.8); Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.groups.isEmpty {
            VStack {
                Spacer()
                Text("Nothing in the icebox")
                    .font(.callout).foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.groups) { group in
                        IceboxGroupSection(
                            group: group,
                            isCollapsed: group.listName.map(model.isCollapsed) ?? false,
                            onToggle: { name in model.toggleCollapse(name) },
                            onOpen: { ItemViewerModel.shared.open($0, over: .icebox) }
                        )
                    }
                }
            }
        }
    }

}
