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

    /// Live width (pixels) while a resize drag is in flight; nil otherwise, at
    /// which point the width is derived from the persisted fraction × the
    /// current window width.
    @State private var draggingWidth: CGFloat? = nil

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
            AgentPaneView()
                .opacity(tabs.selectedTab == .agent ? 1 : 0)
                .allowsHitTesting(tabs.selectedTab == .agent)
                .zIndex(tabs.selectedTab == .agent ? 1 : 0)
                .disabled(viewer.openItem != nil)

            SchedulePaneView()
                .opacity(tabs.selectedTab == .schedule ? 1 : 0)
                .allowsHitTesting(tabs.selectedTab == .schedule)
                .zIndex(tabs.selectedTab == .schedule ? 1 : 0)
                // Disable while hidden so its drag-grip tracking areas — which
                // ignore opacity/hit-testing — can't bleed their cursor through
                // the pane on top; still disabled under the reader as before.
                .disabled(viewer.openItem != nil || tabs.selectedTab != .schedule)

            TasksPaneView()
                .opacity(tabs.selectedTab == .tasks ? 1 : 0)
                .allowsHitTesting(tabs.selectedTab == .tasks)
                .zIndex(tabs.selectedTab == .tasks ? 1 : 0)
                // Disable while hidden so its controls' pointer-cursor tracking
                // can't bleed through the pane on top; still disabled under the
                // reader, matching the other panes.
                .disabled(viewer.openItem != nil || tabs.selectedTab != .tasks)

            IceboxPaneView()
                .opacity(tabs.selectedTab == .icebox ? 1 : 0)
                .allowsHitTesting(tabs.selectedTab == .icebox)
                .zIndex(tabs.selectedTab == .icebox ? 1 : 0)
                // Disable while hidden so its drag-grip tracking areas — which
                // ignore opacity/hit-testing — can't bleed their cursor through
                // the pane on top; still disabled under the reader as before.
                .disabled(viewer.openItem != nil || tabs.selectedTab != .icebox)

            TrashPaneView()
                .opacity(tabs.selectedTab == .trash ? 1 : 0)
                .allowsHitTesting(tabs.selectedTab == .trash)
                .zIndex(tabs.selectedTab == .trash ? 1 : 0)
                // Disable while hidden so its drag-grip tracking areas — which
                // ignore opacity/hit-testing — can't bleed their cursor through
                // the pane on top; still disabled under the reader as before.
                .disabled(viewer.openItem != nil || tabs.selectedTab != .trash)

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
