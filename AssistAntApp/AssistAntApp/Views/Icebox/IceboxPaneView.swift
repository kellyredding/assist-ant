import AppKit
import SwiftUI

/// The Icebox tab's content: a control bar over a scrolled, grouped list of
/// iceboxed items. Snapshot model: the list re-fetches on activation + refresh
/// only. Opening a row hands the item to ItemViewerModel, which presents the
/// reader centrally (above the tab content) and owns its edit session and
/// keystroke handling — the reader is no longer hosted here.
///
/// The pane installs a list-level key monitor for Gmail-style navigation and
/// selection (J/K focus, X toggle, Enter opens, `*a` / `*n` select-all / none),
/// driving the model's shared `ActionableSelection`. It is mutually exclusive
/// with the reader's own monitor: every handler is gated on
/// `ItemViewerModel.openItem == nil` and goes inert while a text field holds
/// focus, so the two monitors never both act on a keystroke.
struct IceboxPaneView: View {
    @ObservedObject private var model = IceboxModel.shared
    @ObservedObject private var selection = IceboxModel.shared.selection
    @ObservedObject private var navigator = MainTabNavigator.shared

    @State private var chords = ActionableListChords()

    var body: some View {
        listPane
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.textBackgroundColor))
            .onAppear {
                if navigator.selectedTab == .icebox { model.activate() }
                chords.install(.init(
                    tab: .icebox,
                    selection: selection,
                    groups: { model.groups },
                    collapsed: { model.collapsedLists },
                    actions: model.actions,
                    open: { ItemViewerModel.shared.open($0, over: .icebox) }
                ))
            }
            .onChange(of: navigator.selectedTab) { _, tab in
                if tab == .icebox { model.activate() }
            }
            .onDisappear { chords.remove() }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            IceboxControlBar(
                groups: model.groups,
                collapsedLists: model.collapsedLists,
                selection: selection,
                actions: model.actions,
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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.groups) { group in
                            ActionableListSection(
                                group: group,
                                isCollapsed: group.listName.map(model.isCollapsed) ?? false,
                                onToggle: { name in model.toggleCollapse(name) },
                                selection: selection,
                                actions: model.actions,
                                onOpen: { item in
                                    // Carry keyboard focus to the opened row so
                                    // returning from the reader leaves it focused.
                                    selection.focus(item.id)
                                    ItemViewerModel.shared.open(item, over: .icebox)
                                }
                            )
                        }
                    }
                }
                // Keep the keyboard-focused row visible as J/K move it.
                .onChange(of: selection.focusedItemID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

}
