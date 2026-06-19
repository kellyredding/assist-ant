import Foundation
import Combine

/// Drives the Schedule tab's agenda. Owns the loaded window and navigation.
/// Both edges are bounded and grow on demand: the past edge (`windowStart`)
/// starts at today and extends via the back chevron; the forward edge
/// (`windowEnd`) starts a fixed horizon ahead and extends as the user scrolls
/// or steps toward it. A bounded forward edge is essential — loading to the
/// furthest future item materializes one empty section per intervening day,
/// and that unbounded row count drowns SwiftUI's layout pass (the agenda
/// beach-balled on accounts with a far-future scheduled item). State persists
/// across tab switches (singleton + the tab view stays mounted); only the
/// first activation jumps to today.
///
/// Each day carries its calendar events and its actionables grouped into
/// sublists. Actionable rows reuse the shared list machinery: selection/focus
/// (`ActionableSelection`, global across days) and the actions cluster
/// (`ActionableActions`, bound to in-place day-snapshot mutations so a chained
/// batch stays visible + undoable until the next refresh).
@MainActor
final class ScheduleAgendaModel: ObservableObject {
    static let shared = ScheduleAgendaModel()

    /// Rendered day sections (windowStart … windowEnd, empty days included).
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

    /// Days materialized ahead of today on first load / today-jump. Large
    /// enough to fill any reasonable viewport without the user hitting an empty
    /// forward edge, small enough that a full layout pass stays cheap.
    private static let forwardHorizon = 45
    /// Days added each time the forward edge is neared, amortizing extension
    /// reloads while keeping the window bounded.
    private static let forwardStep = 45
    /// Start extending when the top visible day is within this many days of the
    /// forward edge, so new sections are ready before the user scrolls to them.
    private static let forwardBuffer = 14

    private let store: ItemStore
    private var windowStart: CivilDate = .today
    /// Forward edge of the materialized range; see the type doc for why it must
    /// stay bounded. Initialized a horizon ahead of today in `init`.
    private var windowEnd: CivilDate = .today
    private var hasActivatedOnce = false

    init(store: ItemStore = GRDBItemStore.shared) {
        self.store = store
        windowEnd = CivilDate.today.adding(days: Self.forwardHorizon)
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
            windowEnd = CivilDate.today.adding(days: Self.forwardHorizon)
            load(spinner: true)
            scrollTarget = .today
        } else {
            refresh()
        }
    }

    /// Re-fetch the current range [windowStart … windowEnd] and regroup, keeping the
    /// scroll position. Also the control-bar refresh glyph's action.
    func refresh() {
        load(spinner: false)
    }

    /// Back chevron: the day above the top day, extending the past edge by
    /// that day if it falls before windowStart.
    func goBack() {
        let target = topVisibleDay.adding(days: -1)
        if target < windowStart {
            windowStart = target
            load(spinner: false)   // extends the rendered range into the past
        }
        scrollTarget = target
    }

    /// Forward chevron: the day below the top day. Extends the forward edge
    /// first if the step lands near it, so stepping never stalls against a
    /// clamped window; otherwise scroll-only within the loaded range.
    func goForward() {
        let target = topVisibleDay.adding(days: 1)
        extendForwardIfNeeded(toShow: target)
        scrollTarget = min(target, days.last?.date ?? target)
    }

    func goToToday() {
        scrollTarget = .today
    }

    /// Called by the agenda's scroll tracker with the topmost-visible day.
    /// Coalesced and guarded: republishes only on an actual day change (so a
    /// stream of near-identical scroll-frame values can't re-trigger layout),
    /// and schedules any forward-edge growth on the next runloop tick rather
    /// than inside the layout pass that produced the value — keeping the
    /// scroll→preference→relayout path from compounding into a hang.
    func updateTopVisibleDay(_ day: CivilDate) {
        guard day != topVisibleDay else { return }
        topVisibleDay = day
        guard day.adding(days: Self.forwardBuffer) >= windowEnd else { return }
        DispatchQueue.main.async { [weak self] in
            self?.extendForwardIfNeeded(toShow: day)
        }
    }

    /// Grow the forward edge so `day` keeps a buffer of loaded days ahead of it,
    /// then reload the (still bounded) range. A no-op away from the edge.
    private func extendForwardIfNeeded(toShow day: CivilDate) {
        guard day.adding(days: Self.forwardBuffer) >= windowEnd else { return }
        windowEnd = day.adding(days: Self.forwardStep)
        load(spinner: false)
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
            reschedule: { items, day in self.reschedule(items, to: day) },
            delete: { items in self.mutateMany(items) { try self.store.softDelete(id: $0) } },
            putBack: { items in self.mutateMany(items) { try self.store.undelete(id: $0) } })
    }

    // MARK: - Drag-and-drop

    /// Drop handling bound to this surface. Schedule accepts items dragged from
    /// the Schedule; a drop reschedules (when the day changed), sets the list
    /// (when it changed), and positions among the destination neighbors. Past
    /// days accept only resolved items — an unresolved item would carry forward
    /// to today regardless.
    var dropHandler: ActionableDropHandler {
        ActionableDropHandler(
            canDrop: { payload, _, day in
                guard payload.surface == .schedule, let day else { return false }
                if day < CivilDate.today && !payload.isResolved { return false }
                return true
            },
            performDrop: { [weak self] payload, list, anchorID, edge, day in
                self?.performDrop(payload, intoList: list, anchor: anchorID, edge: edge, day: day)
            })
    }

    private func performDrop(_ payload: ItemDragSession.Payload,
                             intoList list: String?, anchor anchorID: String?,
                             edge: ItemDragSession.Edge, day: CivilDate?) {
        guard let day, let moved = item(forID: payload.id) else { return }
        let dest = orderedItems(day: day, list: list).filter { $0.id != payload.id }
        let insertIdx = ItemReorder.insertionIndex(in: dest, anchorID: anchorID, edge: edge)
        if payload.day != day { try? store.reschedule(id: payload.id, to: day) }
        if moved.actionableListName != list { try? store.setListName(id: payload.id, to: list) }
        ItemReorder.apply(store: store, destination: dest, movedID: payload.id, insertAt: insertIdx)
        // Reload so the move (including across days) re-buckets at once.
        ActionableSnapshots.refresh()
    }

    private func item(forID id: String) -> Item? {
        for day in days {
            for group in day.actionableGroups {
                if let found = group.items.first(where: { $0.id == id }) { return found }
            }
        }
        return nil
    }

    private func orderedItems(day: CivilDate, list: String?) -> [Item] {
        days.first(where: { $0.date == day })?
            .actionableGroups.first(where: { $0.listName == list })?.items ?? []
    }

    /// Save an edited title + body for one item (the reader's edit, when it
    /// floats over the Schedule). Swaps the row in place so the agenda updates.
    @discardableResult
    func setTitleAndBody(_ item: Item, title: String, body: String?) -> Item? {
        do {
            try store.setTitleAndBody(id: item.id, title: title, body: body)
            if let u = try store.fetch(id: item.id) {
                replaceInPlace(u)
                ActionableSnapshots.refresh(except: .schedule)
                return u
            }
        } catch {
            NSLog("ScheduleAgendaModel: setTitleAndBody failed: \(error)")
        }
        return nil
    }

    /// Set/clear the list name for a set, then regroup each day in place — the
    /// rows move between sublists within their day and are de-selected (a list
    /// move ends the batch).
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
        selection.deselect(updated.map(\.id))
        if !updated.isEmpty { ActionableSnapshots.refresh(except: .schedule) }
        return updated
    }

    /// Reschedule a set onto `day` — a structural move, like a drag: write each,
    /// end the batch, then a FULL refresh so every surface (this Schedule
    /// included) re-buckets the rows to their new day. Mirrors `performDrop`'s
    /// reload rather than the in-place undo-until-refresh path the toggles use.
    @discardableResult
    private func reschedule(_ items: [Item], to day: CivilDate) -> [Item] {
        var updated: [Item] = []
        for item in items {
            do {
                try store.reschedule(id: item.id, to: day)
                if let u = try store.fetch(id: item.id) { updated.append(u) }
            } catch {
                NSLog("ScheduleAgendaModel: reschedule failed for \(item.id): \(error)")
            }
        }
        selection.deselect(updated.map(\.id))
        ActionableSnapshots.refresh()
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
        if !updated.isEmpty { ActionableSnapshots.refresh(except: .schedule) }
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
            let windowed = try store.fetchActive(type: nil, from: windowStart, to: windowEnd)
            let todaySurface = try store.fetchTodaySidebar(asOf: .today)
            let merged = Self.mergeByID(windowed, todaySurface)
            days = ScheduleAgenda.days(
                items: merged, from: windowStart, through: windowEnd, today: .today)
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
