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
            isEmpty: model.calendarRows.isEmpty,
            emptyText: "No events today",
            headerAccessory: AnyView(syncButton)
        ) {
            VStack(spacing: 10) {
                ForEach(model.calendarRows) { row in
                    CalendarItemRow(row: row) {
                        // Cross-tab handoff: switch to Calendar and queue the
                        // event id; CalendarPaneView opens it from the store.
                        let navigator = MainTabNavigator.shared
                        navigator.selectedTab = .calendar
                        navigator.pendingEventShow = row.item.id
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Re-sync affordance in the Calendar header: asks the agent to run the
    /// sync skill. A spinner shows while a sync is in flight; the list updates
    /// itself when the new data lands (TodayItemsModel observes the store).
    @ViewBuilder private var syncButton: some View {
        if sync.isSyncing {
            ProgressView().controlSize(.small)
        } else {
            PointerIconButton(
                systemName: "arrow.clockwise",
                help: "Re-sync calendar with the agent"
            ) {
                CalendarSyncCoordinator.shared.requestSync()
            }
        }
    }

    /// The to-do column — a pinned header now; the list itself lands with the
    /// to-do feature.
    private var todoColumn: some View {
        ItemListSection(
            title: "To-Do",
            emoji: "✅",
            isEmpty: true,
            emptyText: "No to-dos"
        ) {
            EmptyView()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
