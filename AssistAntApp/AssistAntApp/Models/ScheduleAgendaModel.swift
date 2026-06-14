import Foundation
import Combine

/// Drives the Schedule tab's agenda. Owns the loaded window and navigation.
/// Forward data is fully loaded ([windowStart → ∞)); the past edge
/// (`windowStart`) starts at today and extends a Monday-anchored week at a
/// time via the back chevron. State persists across tab switches (singleton +
/// the tab view stays mounted); only the first activation jumps to today.
///
/// Each day carries its calendar events and its actionables grouped into
/// sublists. Actionable rows reuse the shared list machinery: selection/focus
/// (`ActionableSelection`, global across days) and the actions cluster
/// (`ActionableActions`, bound to in-place day-snapshot mutations so a chained
/// batch stays visible + undoable until the next refresh).
@MainActor
final class ScheduleAgendaModel: ObservableObject {
    static let shared = ScheduleAgendaModel()

    /// Rendered day sections (windowStart … last item day).
    @Published private(set) var days: [AgendaDay] = []
    /// First-load spinner. Back-load / refresh use `isWorking` so the existing
    /// content stays on screen.
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    /// A day the view should scroll to (anchor .top), consumed once.
    @Published var scrollTarget: CivilDate?
    /// Topmost visible day, written by the view's scroll tracker; drives the
    /// month/year label and is the anchor the chevrons jump relative to.
    @Published var topVisibleDay: CivilDate = .today
    /// Collapsed actionable sublists by list name (applies across days).
    @Published private(set) var collapsedLists: Set<String> = []

    /// Selection + keyboard focus for the agenda's actionable rows — global, so
    /// J/K and a batch span days. Observed directly by the rows + control bar.
    let selection = ActionableSelection()

    private let store: ItemStore
    private var windowStart: CivilDate = .today
    private var hasActivatedOnce = false

    init(store: ItemStore = GRDBItemStore.shared) {
        self.store = store
        // Re-fetch the window when a sync commits calendar data...
        NotificationCenter.default.addObserver(
            forName: .calendarItemsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleItemsChanged() }
        }
        // ...and when actionables change (a Linear sync now lands scheduled
        // todos on the agenda too), same windowed-refresh pattern.
        NotificationCenter.default.addObserver(
            forName: .actionableItemsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleItemsChanged() }
        }
    }

    private func handleItemsChanged() {
        guard hasActivatedOnce else { return }
        refresh()
    }

    /// Tab became active. First time: load [today → ∞), anchor today at top.
    /// Every time: refresh the rendered range so newly-synced items appear.
    func activate() {
        if !hasActivatedOnce {
            hasActivatedOnce = true
            windowStart = .today
            load(spinner: true)
            scrollTarget = .today
        } else {
            refresh()
        }
    }

    /// Re-fetch the current range [windowStart → ∞) and regroup, keeping the
    /// scroll position. Also the control-bar refresh glyph's action.
    func refresh() {
        load(spinner: false)
    }

    /// Back chevron: previous Monday above the top day (snap to this week's
    /// Monday if mid-week), loading past days if it's before windowStart.
    func goBack() {
        let top = topVisibleDay
        let thisMonday = top.mondayOfWeek()
        let target = (top == thisMonday) ? thisMonday.adding(days: -7) : thisMonday
        if target < windowStart {
            windowStart = target
            load(spinner: false)   // extends the rendered range into the past
        }
        scrollTarget = target
    }

    /// Forward chevron: next Monday below the top day. Forward data is already
    /// loaded, so this is scroll-only (clamped to the last rendered day).
    func goForward() {
        let nextMonday = topVisibleDay.mondayOfWeek().adding(days: 7)
        scrollTarget = min(nextMonday, days.last?.date ?? nextMonday)
    }

    func goToToday() {
        scrollTarget = .today
    }

    func toggleCollapse(_ listName: String) {
        if collapsedLists.contains(listName) {
            collapsedLists.remove(listName)
        } else {
            collapsedLists.insert(listName)
        }
    }

    func isCollapsed(_ listName: String) -> Bool {
        collapsedLists.contains(listName)
    }

    // MARK: - Actionable rows: selection feed + action API

    /// Every day's actionable groups, flattened in render order — the basis for
    /// the visible-id order, the selection feed, and `*a` scoping.
    var allGroups: [ActionableGroup] { days.flatMap(\.actionableGroups) }

    /// The selected actionables in visible (top→bottom across days) order.
    var selectedItems: [Item] {
        selection.selectedItems(in: allGroups, collapsed: collapsedLists)
    }

    /// The cluster's actions, bound to this model's in-place day-snapshot
    /// mutations, so `ItemActions` drives the agenda without referencing it.
    var actions: ActionableActions {
        ActionableActions(
            complete: { items in self.mutateMany(items) { try self.store.completeActionable(id: $0) } },
            reopen: { items in self.mutateMany(items) { try self.store.reopenActionable(id: $0) } },
            moveToIcebox: { items in self.mutateMany(items) { try self.store.setIceboxed(id: $0, true) } },
            removeFromIcebox: { items in self.mutateMany(items) { try self.store.setIceboxed(id: $0, false) } },
            reclassify: { items, type in self.mutateMany(items) { try self.store.reclassify(id: $0, to: type) } },
            setListName: { items, name in self.setListName(items, to: name) },
            delete: { items in self.mutateMany(items) { try self.store.softDelete(id: $0) } },
            putBack: { items in self.mutateMany(items) { try self.store.undelete(id: $0) } })
    }

    /// Save an edited title + body for one item (the reader's edit, when it
    /// floats over the Schedule). Swaps the row in place so the agenda updates.
    @discardableResult
    func setTitleAndBody(_ item: Item, title: String, body: String?) -> Item? {
        do {
            try store.setTitleAndBody(id: item.id, title: title, body: body)
            if let u = try store.fetch(id: item.id) { replaceInPlace(u); return u }
        } catch {
            NSLog("ScheduleAgendaModel: setTitleAndBody failed: \(error)")
        }
        return nil
    }

    /// Set/clear the list name for a set, then regroup each day in place — the
    /// rows move between sublists within their day and stay selected/undoable.
    @discardableResult
    private func setListName(_ items: [Item], to listName: String?) -> [Item] {
        var updated: [Item] = []
        for item in items {
            do {
                try store.setListName(id: item.id, to: listName)
                if let u = try store.fetch(id: item.id) { replaceInPlace(u); updated.append(u) }
            } catch {
                NSLog("ScheduleAgendaModel: setListName failed for \(item.id): \(error)")
            }
        }
        regroupInPlace()
        return updated
    }

    /// Apply `op` per id, re-read each row, swap it into its day's group in
    /// place, and return the updated rows. Non-structural state (resolve, icebox
    /// flag) shows immediately while the row keeps its slot until refresh.
    @discardableResult
    private func mutateMany(_ items: [Item], _ op: (String) throws -> Void) -> [Item] {
        var updated: [Item] = []
        for item in items {
            do {
                try op(item.id)
                if let u = try store.fetch(id: item.id) {
                    replaceInPlace(u)
                    updated.append(u)
                }
            } catch {
                NSLog("ScheduleAgendaModel: action failed for \(item.id): \(error)")
            }
        }
        return updated
    }

    private func replaceInPlace(_ updated: Item) {
        for (d, day) in days.enumerated() {
            for (g, group) in day.actionableGroups.enumerated() {
                if let i = group.items.firstIndex(where: { $0.id == updated.id }) {
                    var groups = day.actionableGroups
                    var items = group.items
                    items[i] = updated
                    groups[g] = ActionableGroup(listName: group.listName, items: items)
                    days[d] = AgendaDay(date: day.date, events: day.events, actionableGroups: groups)
                    return
                }
            }
        }
    }

    /// Re-bucket each day's actionables from the current snapshot (no store
    /// round-trip), so a list change moves a row to a different sublist within
    /// its day while resolved / iceboxed rows are retained until refresh.
    private func regroupInPlace() {
        days = days.map { day in
            AgendaDay(
                date: day.date,
                events: day.events,
                actionableGroups: ActionableGrouping.groups(items: day.actionableGroups.flatMap(\.items)))
        }
    }

    /// Union two item sets by id (first occurrence wins; the windowed and
    /// Today-sidebar queries return the same row for any overlap, so order is
    /// immaterial — ScheduleAgenda re-buckets and re-sorts).
    private static func mergeByID(_ a: [Item], _ b: [Item]) -> [Item] {
        var byID: [String: Item] = [:]
        for item in a + b where byID[item.id] == nil { byID[item.id] = item }
        return Array(byID.values)
    }

    private func load(spinner: Bool) {
        if spinner { isLoading = true } else { isWorking = true }
        do {
            // All types in the window: calendar events + scheduled actionables
            // (resolved kept for history; iceboxed excluded by the store). Plus
            // the Today sidebar's working set — the unscheduled + overdue open
            // actionables that surface on Today but carry no in-window
            // scheduled_on — so the today column mirrors the Today list.
            // ScheduleAgenda routes each (merged, deduped) item to its day.
            let windowed = try store.fetchActive(type: nil, from: windowStart, to: nil)
            let todaySurface = try store.fetchTodaySidebar(asOf: .today)
            let merged = Self.mergeByID(windowed, todaySurface)
            days = ScheduleAgenda.days(items: merged, from: windowStart, today: .today)
        } catch {
            NSLog("ScheduleAgendaModel: load failed: \(error)")
        }
        selection.reconcile(
            visible: ActionableListNavigation.visibleIDs(allGroups, collapsed: collapsedLists),
            present: Set(allGroups.flatMap(\.items).map { $0.id }))
        isLoading = false
        isWorking = false
    }
}
