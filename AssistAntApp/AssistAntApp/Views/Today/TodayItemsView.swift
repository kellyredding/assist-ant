import SwiftUI

/// The today sidebar's item area, below the clock and divider. Arranges item
/// sections into one or two columns based on the committed sidebar width —
/// reusing the titlebar toggle's threshold so the two never disagree. Today it
/// renders the Calendar section in the (left) column; the right column is
/// reserved for the Todo / Reminder / Explore lists that land next.
struct TodayItemsView: View {
    @StateObject private var model = TodayItemsModel()
    @ObservedObject private var layout = SidebarLayoutModel.shared
    @ObservedObject private var sync = CalendarSyncCoordinator.shared
    @ObservedObject private var linearSync = LinearSyncCoordinator.shared
    @ObservedObject private var drag = ItemDragSession.shared

    private var isExpanded: Bool {
        layout.fraction >= SidebarMetrics.toggleThreshold
    }

    // The items area fills the full height of the sidebar below the clock. Each
    // column is its own scroll view, so the columns fill that bounded height —
    // which is what gives the divider its full height — and each scrolls
    // independently when its own list overflows.
    var body: some View {
        Group {
            if isExpanded {
                HStack(alignment: .top, spacing: 0) {
                    calendarColumn
                    Divider()
                    todoColumn
                }
            } else {
                // One column: stack both lists, each taking half the height so
                // both are visible; each scrolls within its own half.
                VStack(spacing: 0) {
                    calendarColumn
                    Divider()
                    todoColumn
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var calendarColumn: some View {
        ItemListSection(
            title: "Calendar / Reminders",
            emoji: "📅",
            isEmpty: model.calendarRows.isEmpty && model.reminderGroups.isEmpty,
            emptyText: "Nothing today",
            headerAccessory: AnyView(syncButton)
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.calendarRows) { row in
                    CalendarItemRow(row: row) {
                        // Open the event in the shared reader over the Schedule
                        // tab, so closing it (Esc / ✕) lands back on Schedule.
                        ItemViewerModel.shared.open(row.item, over: .schedule)
                    }
                }
                // Reminders live beneath the day's events, grouped into sublists.
                if !model.reminderGroups.isEmpty {
                    if !model.calendarRows.isEmpty { Divider().padding(.vertical, 2) }
                    actionableGroups(model.reminderGroups, column: .reminder)
                }
                columnDropPlaceholder(.reminder, groups: model.reminderGroups)
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Re-sync affordance in the Calendar header: reconstitutes the list now
    /// (releasing any held rows), then asks the agent to run the sync skill. A
    /// spinner shows while the sync is in flight; items it commits arrive on
    /// their own through the live feed.
    @ViewBuilder private var syncButton: some View {
        if sync.isSyncing {
            ProgressView().controlSize(.small)
        } else {
            PointerIconButton(
                systemName: "arrow.clockwise",
                help: "Re-sync calendar with the agent"
            ) {
                model.refresh()
                TaskRunner.runCalendarGlyph()
            }
        }
    }

    /// The to-do / explore column: the day's to-dos and explores, grouped into
    /// named + unnamed sublists.
    private var todoColumn: some View {
        ItemListSection(
            title: "Todo / Explore",
            emoji: "✅",
            isEmpty: model.todoExploreGroups.isEmpty,
            emptyText: "Nothing for today",
            headerAccessory: AnyView(linearSyncButton)
        ) {
            VStack(alignment: .leading, spacing: 0) {
                actionableGroups(model.todoExploreGroups, column: .todoExplore)
                columnDropPlaceholder(.todoExplore, groups: model.todoExploreGroups)
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Render actionable groups as the shared list sections in the Today
    /// context: no selection gutter and glyph hover actions, tapping a row opens
    /// the reader over the Schedule tab. Sublists collapse via the model.
    /// While a Today drag is in flight, offer a placeholder at the base of a
    /// column that doesn't yet carry the dragged item's list — so you can move
    /// between the Reminders and Todo/Explore columns while keeping the list
    /// name (e.g. dropping into "no list" when the column has only named lists).
    /// Mirrors the Schedule absent-list slot. Note: when a column is fully empty
    /// it renders its empty state instead of rows, so the slot can't show there.
    @ViewBuilder
    private func columnDropPlaceholder(_ column: TodayColumn, groups: [ActionableGroup]) -> some View {
        if let p = drag.payload, p.surface == .today,
           !groups.contains(where: { $0.listName == p.listName }) {
            AbsentListDropSlot(listName: p.listName, day: nil, handler: model.dropHandler(for: column))
        }
    }

    @ViewBuilder
    private func actionableGroups(_ groups: [ActionableGroup], column: TodayColumn) -> some View {
        ForEach(groups) { group in
            ActionableListSection(
                group: group,
                isCollapsed: model.isCollapsed(group.id),
                onToggle: { model.toggleCollapse($0) },
                actions: model.actions,
                onOpen: { ItemViewerModel.shared.open($0, over: .schedule) },
                context: .today,
                dropHandler: model.dropHandler(for: column)
            )
        }
    }

    /// Re-sync affordance in the To-Do header: reconstitutes the list now
    /// (releasing any held rows), then asks the agent to run the Linear sync
    /// skill. A spinner shows while the sync is in flight; items it commits
    /// arrive on their own through the live feed.
    @ViewBuilder private var linearSyncButton: some View {
        if linearSync.isSyncing {
            ProgressView().controlSize(.small)
        } else {
            PointerIconButton(
                systemName: "arrow.clockwise",
                help: "Re-sync to-dos with the agent"
            ) {
                model.refresh()
                TaskRunner.runLinearGlyph()
            }
        }
    }
}
