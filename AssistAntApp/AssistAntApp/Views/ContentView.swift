import SwiftUI

/// Root content of the main AssistAnt window. A resizable, non-collapsible
/// left sidebar hosts the clock; the right pane hosts the agent (currently a
/// placeholder). The split is a plain `HStack` with a hand-rolled AppKit drag
/// handle rather than a split-view class — the same approach Galaxy uses
/// (~/projects/kellyredding/galaxy/GalaxyApp/GalaxyApp/ContentView.swift).
///
/// The sidebar width is a *fraction* of the window width (0.25–0.50), held in
/// `SidebarLayoutModel`. Because it's a ratio, both panes always keep a
/// proportional share at any window size — so there's no minimum-width math
/// and no starvation case. Dragging the divider adjusts the fraction within
/// the band; the titlebar toggle snaps it to the far extreme. The clock
/// scales its fonts to fit the resulting width (see ClockView / ClockMetrics).
struct ContentView: View {
    @ObservedObject private var layout = SidebarLayoutModel.shared
    @ObservedObject private var tabs = MainTabNavigator.shared
    @ObservedObject private var viewer = ItemViewerModel.shared

    /// Active state of the window hosting this view. ContentView is only ever
    /// hosted in the main window, so this tracks the main window specifically.
    /// `.inactive` means the app is not the frontmost application — distinct
    /// from `.active` (app frontmost, but another of its own windows is key,
    /// e.g. Settings or the capture panel), so the right pane dims only when
    /// the app itself loses focus, not when focus moves to a sibling window.
    @Environment(\.controlActiveState) private var controlActiveState

    /// Live width (pixels) while a resize drag is in flight; nil otherwise, at
    /// which point the width is derived from the persisted fraction × the
    /// current window width.
    @State private var draggingWidth: CGFloat? = nil

    /// Right-pane opacity while the app is inactive. Only the right pane dims:
    /// it owns the keyboard-driven surfaces (schedule shortcuts, etc.), so the
    /// dim doubles as an at-a-glance "are shortcuts live?" cue. The today
    /// sidebar stays full-bright so it remains readable as a reference even on
    /// an unfocused side monitor. A touch stronger than the unfocused dimming
    /// Galaxy applies to its panes (0.55–0.70) so the unfocused state is
    /// unmistakable at a glance.
    private static let inactiveDimOpacity: CGFloat = 0.4

    var body: some View {
        GeometryReader { geo in
            let windowWidth = geo.size.width
            let minWidth = windowWidth * SidebarMetrics.minFraction
            let maxWidth = windowWidth * SidebarMetrics.maxFraction
            let sidebarWidth = draggingWidth ?? (windowWidth * layout.fraction)

            HStack(spacing: 0) {
                sidebarColumn(width: sidebarWidth)
                resizeHandle(
                    currentWidth: sidebarWidth,
                    minWidth: minWidth,
                    maxWidth: maxWidth,
                    windowWidth: windowWidth
                )
                rightColumn
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Sidebar Column

    /// The today sidebar: the clock in a top band (scaling its fonts to the
    /// sidebar width — see ClockView / ClockMetrics), a divider, then today's
    /// items filling the rest of the column.
    private func sidebarColumn(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            ClockView()
            Divider()
            TodayItemsView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .clipped()
        .transaction { t in
            // Suppress implicit animation during the resize drag so the
            // column tracks the cursor 1:1 instead of easing behind it.
            if draggingWidth != nil {
                t.animation = nil
            }
        }
    }

    // MARK: - Right Column (tab bar + content)

    /// The right pane: a thin centered tab bar on top (Galaxy's control-bar
    /// pattern), then the switched tab content filling the rest.
    private var rightColumn: some View {
        VStack(spacing: 0) {
            tabControlBar
            tabContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(controlActiveState == .inactive ? Self.inactiveDimOpacity : 1)
        .animation(.easeInOut(duration: 0.18), value: controlActiveState)
    }

    /// Flat tab strip centered over the right pane, with a hairline bottom
    /// divider — mirrors Galaxy's viewsControlBar
    /// (~/projects/kellyredding/galaxy/GalaxyApp/GalaxyApp/ContentView.swift).
    private var tabControlBar: some View {
        HStack(spacing: 0) {
            Spacer()
            MainTabBar()
            Spacer()
        }
        .frame(height: 30)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
        }
    }

    // MARK: - Tab Content (right pane)

    /// The right-pane view switcher. Every tab view stays mounted; only
    /// opacity / hit-testing / z-order change on switch (no rebuild) — the
    /// performance behavior carried over from Galaxy. With one tab this is a
    /// ZStack of one; each future case adds one stacked view + its toggles.
    private var tabContent: some View {
        ZStack {
            // The agent terminal manages its own active state and has no bleeding
            // affordances, so it stays enabled while hidden — disabled only under
            // the reader (gateWhenHidden: false). The other panes quiet while
            // hidden so their drag-grip / pointer-cursor tracking — which ignores
            // opacity and hit-testing — can't bleed through the pane on top.
            AgentPaneView()
                .tabPane(.agent, selected: tabs.selectedTab,
                         covered: viewer.openItem != nil, gateWhenHidden: false)

            SchedulePaneView()
                .tabPane(.schedule, selected: tabs.selectedTab,
                         covered: viewer.openItem != nil)

            TasksPaneView()
                .tabPane(.tasks, selected: tabs.selectedTab,
                         covered: viewer.openItem != nil)

            IceboxPaneView()
                .tabPane(.icebox, selected: tabs.selectedTab,
                         covered: viewer.openItem != nil)

            TrashPaneView()
                .tabPane(.trash, selected: tabs.selectedTab,
                         covered: viewer.openItem != nil)

            // The item reader is presented once here, above whichever tab is
            // selected, so it can be launched from any tab and float over it.
            // The panes stay mounted but disabled beneath (preserving scroll
            // position); zIndex keeps it above the selected pane's zIndex of 1.
            if let item = viewer.openItem {
                itemReader(for: item)
                    .zIndex(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: tabs.selectedTab) { _, newTab in
            viewer.tabChanged(to: newTab)
        }
        .onAppear { viewer.restoreIfNeeded() }
    }

    /// Dispatch to the right reader by item type: calendar events are
    /// read-only; actionable items (todo / reminder / explore) edit via the
    /// session the presenter hosts.
    @ViewBuilder
    private func itemReader(for item: Item) -> some View {
        if case .calendar = item.typeData {
            CalendarEventViewer(event: item, onClose: { viewer.close() })
        } else {
            ActionableItemViewer(
                item: item,
                isTrash: viewer.isTrashReader,
                edit: viewer.edit,
                actions: viewer.actions,
                onClose: { viewer.close() },
                onItemChange: { viewer.updateOpenItem($0) },
                onBeginEdit: { viewer.beginEdit() },
                onCancelEdit: { viewer.cancelEdit() },
                onSave: { viewer.saveEdit() }
            )
        }
    }

    // MARK: - Resize Handle

    /// A 1pt separator line overlaid with a wider invisible AppKit drag
    /// target. `minWidth`/`maxWidth` are the live window-relative 25% / 50%
    /// bounds; on drag-end the final width is converted back to a fraction
    /// and persisted so the ratio survives later window resizes.
    private func resizeHandle(
        currentWidth: CGFloat,
        minWidth: CGFloat,
        maxWidth: CGFloat,
        windowWidth: CGFloat
    ) -> some View {
        Rectangle()
            .fill(Color(NSColor.separatorColor))
            .frame(width: 1)
            .overlay {
                SidebarResizeHandle(
                    currentWidth: currentWidth,
                    minWidth: minWidth,
                    maxWidth: maxWidth,
                    onWidthChange: { newWidth in
                        draggingWidth = newWidth
                    },
                    onDragEnd: { finalWidth in
                        draggingWidth = nil
                        guard windowWidth > 0 else { return }
                        layout.setFraction(finalWidth / windowWidth)
                    }
                )
                .frame(width: 9)
            }
            .zIndex(100)
    }
}
