import Foundation
import Combine

/// Drives the today sidebar's lists. Three feeds, all rolled over at local
/// midnight by the clock:
///  - **Calendar rows** — the live active calendar feed × the clock (the minute
///    tick re-evaluates each row's past/upcoming state and rolls the day over).
///  - **Reminder rows** and **to-do / explore rows** — derived from the store's
///    Today-sidebar feed, a *snapshot working set* layered over a live feed.
///
/// The snapshot/dim/hold rule: external changes (from the Icebox/Schedule tabs,
/// or items a sync commits) flow through the live feed and show instantly; the
/// sidebar's OWN actions that take a row out of today (move to icebox /
/// reschedule into the future) hold the row in place, dimmed. A held row is
/// released only when the user hits the column's refresh glyph (`refresh()`) or
/// the day rolls over — the click clears the holds up front and *then* kicks off
/// the sync, so the list settles immediately rather than waiting on the sync.
/// Resolved-today items stay (struck) until the rollover.
@MainActor
final class TodayItemsModel: ObservableObject {
    @Published private(set) var calendarRows: [TodayCalendarRow] = []
    /// Reminder rows for the left column, grouped into named + unnamed sublists.
    @Published private(set) var reminderGroups: [ActionableGroup] = []
    /// To-do + explore rows for the right column, grouped into sublists.
    @Published private(set) var todoExploreGroups: [ActionableGroup] = []
    /// Collapsed named sublists by list name. In-memory for the session.
    @Published private(set) var collapsedLists: Set<String> = []

    /// Ids the sidebar's OWN action took out of today (moved to icebox /
    /// rescheduled into the future). Held — kept visible and dimmed — until the
    /// refresh glyph (`refresh()`) or the rollover releases them. Combined with
    /// the live feed so a held row never drops mid-action.
    @Published private var heldIDs: Set<String> = []

    private let store: ItemStore
    private var cancellables = Set<AnyCancellable>()
    /// The Today-sidebar feed subscription, replaced at the midnight rollover.
    private var feedCancellable: AnyCancellable?

    init(store: ItemStore = GRDBItemStore.shared,
         clock: ClockService = .shared) {
        self.store = store

        // Calendar rows: live calendar feed × clock tick.
        let items = store.observeActive(type: .calendar).replaceError(with: [])
        Publishers.CombineLatest(items, clock.$currentTime)
            .map { items, now in TodayCalendar.rows(items: items, now: now) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$calendarRows)

        // (Re)subscribe the actionable feed whenever the civil day changes: the
        // first tick subscribes for today; crossing local midnight re-subscribes
        // for the new day (which also clears yesterday's held rows).
        clock.$currentTime
            .map { CivilDate($0) }
            .removeDuplicates()
            .sink { [weak self] day in self?.subscribeFeed(asOf: day) }
            .store(in: &cancellables)
        // No sync-completion observer: held rows release on the refresh glyph
        // (see `refresh()`) or the rollover, and items a sync commits surface on
        // their own through the live feed above — so reconstitution isn't tied
        // to the sync finishing.
    }

    // MARK: - Sublist collapse

    func toggleCollapse(_ listName: String) {
        if collapsedLists.contains(listName) {
            collapsedLists.remove(listName)
        } else {
            collapsedLists.insert(listName)
        }
    }

    func isCollapsed(_ listName: String) -> Bool { collapsedLists.contains(listName) }

    // MARK: - Snapshot feed + held overlay

    /// Subscribe the Today-sidebar feed for `day`, combined with `heldIDs` so the
    /// displayed set is the live today set plus any rows the sidebar is holding
    /// in place until a refresh. Re-subscribing (rollover) clears the holds.
    private func subscribeFeed(asOf day: CivilDate) {
        heldIDs.removeAll()
        let feed = store.observeTodaySidebar(asOf: day).replaceError(with: [])
        feedCancellable = Publishers.CombineLatest(feed, $heldIDs)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] live, held in
                self?.regroup(live: live, held: held)
            }
    }

    /// The refresh-glyph action: release the held rows so the live set alone
    /// defines the list — the held rows (now iceboxed or future-scheduled) fall
    /// out at once. The view pairs this with kicking off the sync; items the
    /// sync then commits arrive on their own through the live feed.
    func refresh() { heldIDs.removeAll() }

    /// Build the displayed set (live ∪ held), split it by kind, and regroup each
    /// half into sublists. A held id missing from the live set is re-fetched for
    /// its current (dimmed) state; one that no longer exists is dropped.
    private func regroup(live: [Item], held: Set<String>) {
        var byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in held where byID[id] == nil {
            // A held row absent from the live set is re-fetched for its dimmed
            // state — including a soft-deleted row (delete holds it in place so it
            // can be put back from here); only a truly-missing row drops.
            if let item = try? store.fetch(id: id) {
                byID[id] = item
            }
        }
        let items = Array(byID.values)
        let reminders = items.filter { $0.type == ItemType.reminder.rawValue }
        let todoExplore = items.filter {
            $0.type == ItemType.todo.rawValue || $0.type == ItemType.explore.rawValue
        }
        reminderGroups = ActionableGrouping.groups(items: reminders)
        todoExploreGroups = ActionableGrouping.groups(items: todoExplore)
    }

    // MARK: - Actions (bound to the store; hold rows that leave today)

    /// The cluster's actions for the sidebar's hover glyphs. Each performs the
    /// store mutation (the live feed re-emits from the write) and adjusts the
    /// held set: move-to-icebox holds the row in place dimmed, remove-from-icebox
    /// releases it, while resolve/restore/reclassify/list changes keep the row in
    /// the live set and need no hold.
    var actions: ActionableActions {
        ActionableActions(
            complete: { self.apply($0, hold: nil) { try self.store.completeActionable(id: $0) } },
            reopen: { self.apply($0, hold: nil) { try self.store.reopenActionable(id: $0) } },
            moveToIcebox: { self.apply($0, hold: true) { try self.store.setIceboxed(id: $0, true) } },
            removeFromIcebox: { self.apply($0, hold: false) { try self.store.setIceboxed(id: $0, false) } },
            reclassify: { items, type in self.apply(items, hold: nil) { try self.store.reclassify(id: $0, to: type) } },
            setListName: { items, name in self.apply(items, hold: nil) { try self.store.setListName(id: $0, to: name) } },
            delete: { self.apply($0, hold: true) { try self.store.softDelete(id: $0) } },
            putBack: { self.apply($0, hold: false) { try self.store.undelete(id: $0) } })
    }

    /// Run `op` per item; adjust the held set (`true` = hold the row dimmed in
    /// place after it leaves today, `false` = release a held row, `nil` = leave
    /// the holds as-is); return the updated rows so a reader's onChange can
    /// refresh. The live feed drives the re-render.
    @discardableResult
    private func apply(_ items: [Item], hold: Bool?,
                       _ op: (String) throws -> Void) -> [Item] {
        var updated: [Item] = []
        for item in items {
            do {
                try op(item.id)
                switch hold {
                case .some(true): heldIDs.insert(item.id)
                case .some(false): heldIDs.remove(item.id)
                case .none: break
                }
                if let u = try store.fetch(id: item.id) { updated.append(u) }
            } catch {
                NSLog("TodayItemsModel: action failed for \(item.id): \(error)")
            }
        }
        if !updated.isEmpty { refreshSnapshotSurfaces() }
        return updated
    }

    /// Re-fetch the snapshot surfaces (the Icebox + Schedule tabs) after an
    /// in-sidebar mutation, so an item moved to the icebox or rescheduled from
    /// the Today sidebar reflects on those tabs immediately. Calls them directly
    /// rather than posting `.actionableItemsDidChange` — that notification also
    /// clears the sync coordinators' spinners, and an in-sidebar action is not a
    /// sync completion. The sidebar's own held rows are untouched.
    private func refreshSnapshotSurfaces() {
        IceboxModel.shared.refresh()
        ScheduleAgendaModel.shared.refresh()
        TrashModel.shared.refresh()
    }
}
