import AppKit
import SwiftUI

/// The Trash tab's content: a control bar over a scrolled, grouped list of
/// soft-deleted items. Snapshot model: the list re-fetches on activation +
/// refresh only. Opening a row hands the item to ItemViewerModel, which presents
/// the reader (read-only for a trashed item) centrally above the tab content.
///
/// Mirrors IceboxPaneView — same list-level key monitor for Gmail-style
/// navigation and selection (J/K focus, X toggle, Enter opens, `*a` / `*n`
/// select-all / none), mutually exclusive with the reader's own monitor (gated
/// on `ItemViewerModel.openItem == nil` and inert while a text field holds
/// focus). The leader chords resolve `a p` (Put back) on this surface.
struct TrashPaneView: View {
    @ObservedObject private var model = TrashModel.shared
    @ObservedObject private var selection = TrashModel.shared.selection
    @ObservedObject private var navigator = MainTabNavigator.shared
    @ObservedObject private var viewer = ItemViewerModel.shared

    @State private var chords = ActionableListChords()

    var body: some View {
        listPane
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.textBackgroundColor))
            .onAppear {
                if navigator.selectedTab == .trash { model.activate() }
                syncChords()
            }
            .onChange(of: navigator.selectedTab) { _, tab in
                if tab == .trash { model.activate() }
                syncChords()
            }
            .onChange(of: viewer.openItem) { _, _ in syncChords() }
            .onDisappear { chords.remove() }
    }

    /// Install the list key monitor only while this pane is the active surface —
    /// the Trash tab selected and no reader open. Otherwise remove it, keeping a
    /// single actionable key monitor live at a time (see IceboxPaneView).
    private func syncChords() {
        guard navigator.selectedTab == .trash, viewer.openItem == nil else {
            chords.remove(); return
        }
        chords.install(.init(
            tab: .trash,
            selection: selection,
            groups: { model.groups },
            collapsed: { model.collapsedLists },
            actions: model.actions,
            open: { ItemViewerModel.shared.open($0, over: .trash) }
        ))
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            TrashControlBar(
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
                Text("Trash is empty")
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
                                isCollapsed: model.isCollapsed(group.id),
                                onToggle: { name in model.toggleCollapse(name) },
                                selection: selection,
                                actions: model.actions,
                                onOpen: { item in
                                    // Carry keyboard focus to the opened row so
                                    // returning from the reader leaves it focused.
                                    selection.focus(item.id)
                                    ItemViewerModel.shared.open(item, over: .trash)
                                },
                                context: .trash,
                                dropHandler: model.dropHandler
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
