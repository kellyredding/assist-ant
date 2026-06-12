import Foundation
import Combine

/// Drives the Icebox tab. Snapshot/refresh like ScheduleAgendaModel: the
/// list re-fetches only on activation and the refresh glyph, never live.
/// Row actions mutate the in-memory snapshot in place (so a row's
/// appearance changes without the list re-sorting or dropping it), letting
/// an accidental Done / Move be undone until the next refresh.
@MainActor
final class IceboxModel: ObservableObject {
    static let shared = IceboxModel()

    @Published private(set) var groups: [IceboxGroup] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    /// Collapsed named lists (by list name). In-memory for the session;
    /// survives tab switches (singleton) but not relaunch.
    @Published private(set) var collapsedLists: Set<String> = []
    /// Rows selected for batch actions, by item id — survives regrouping so a
    /// chained selection stays visible and undoable.
    @Published private(set) var selectedIDs: Set<String> = []
    /// The row receiving X / Enter (the focus bar), by item id. Distinct from
    /// selection: a row can be focused without being selected and vice-versa.
    @Published private(set) var focusedItemID: String?

    private let store: ItemStore
    private var hasActivatedOnce = false

    init(store: ItemStore = GRDBItemStore.shared) {
        self.store = store
        // A Linear actionable sync commits new icebox rows; refresh when one
        // lands (same pattern as ScheduleAgendaModel + .calendarItemsDidChange).
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

    func activate() {
        if !hasActivatedOnce {
            hasActivatedOnce = true
            load(spinner: true)
        } else {
            refresh()
        }
    }

    /// Control-bar refresh glyph. Re-fetches and regroups, dropping
    /// acted-on rows (resolved / moved are excluded by fetchIceboxed).
    func refresh() { load(spinner: false) }

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

    // MARK: - Selection & focus (by item id, survives regrouping)

    var hasSelection: Bool { !selectedIDs.isEmpty }

    /// The selected items in visible (top→bottom) order, for feeding the
    /// batch cluster.
    var selectedItems: [Item] {
        let order = IceboxNavigation.visibleIDs(groups, collapsed: collapsedLists)
        let byID = Dictionary(
            uniqueKeysWithValues: groups.flatMap(\.items).map { ($0.id, $0) })
        return order.filter(selectedIDs.contains).compactMap { byID[$0] }
    }

    /// The currently focused item, for Enter-to-open.
    var focusedItem: Item? {
        guard let focusedItemID else { return nil }
        return groups.flatMap(\.items).first { $0.id == focusedItemID }
    }

    func toggleSelected(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }
    func clearSelection() { selectedIDs.removeAll() }            // *n
    func selectAllInFocusedGroup() {                             // *a
        selectedIDs.formUnion(IceboxNavigation.idsInGroup(of: focusedItemID, groups))
    }

    func focus(_ id: String?) { focusedItemID = id }
    func toggleSelectedFocused() { if let id = focusedItemID { toggleSelected(id) } }   // X
    func moveFocus(by delta: Int) {
        let order = IceboxNavigation.visibleIDs(groups, collapsed: collapsedLists)
        focusedItemID = IceboxNavigation.step(from: focusedItemID, by: delta, in: order)
    }

    // MARK: - Row actions (mutate store + snapshot, no re-fetch)
    //
    // The action surface takes a SET of items so one cluster (row hover, reader,
    // and the batch control bar) can drive it. A single-item caller passes
    // [item]; the return is the updated rows. `mutateMany` is the set form of
    // `mutate`.

    @discardableResult
    func complete(_ items: [Item]) -> [Item] {
        mutateMany(items) { try store.completeActionable(id: $0) }
    }
    @discardableResult
    func reopen(_ items: [Item]) -> [Item] {
        mutateMany(items) { try store.reopenActionable(id: $0) }
    }
    @discardableResult
    func moveToIcebox(_ items: [Item]) -> [Item] {
        mutateMany(items) { try store.setIceboxed(id: $0, true) }
    }
    @discardableResult
    func removeFromIcebox(_ items: [Item]) -> [Item] {
        mutateMany(items) { try store.setIceboxed(id: $0, false) }
    }
    @discardableResult
    func reclassify(_ items: [Item], to type: ItemType) -> [Item] {
        mutateMany(items) { try store.reclassify(id: $0, to: type) }
    }

    /// Save an edited title + body for one item (the reader's edit). Not
    /// structural, so the row swaps in place — the list-row title + body preview
    /// refresh with it.
    @discardableResult
    func setTitleAndBody(_ item: Item, title: String, body: String?) -> Item? {
        mutate(item) { try store.setTitleAndBody(id: $0, title: title, body: body) }
    }

    /// Distinct list names in use, for the list-editor combobox suggestions.
    func knownListNames() -> [String] {
        (try? store.knownListNames()) ?? []
    }

    /// Set or clear the list name for a set, then regroup. A list change is
    /// structural — items move to a different group — so it re-buckets the
    /// snapshot in place rather than re-fetching: update each item's list in
    /// the store, re-read it, swap it into the snapshot, then regroup locally.
    /// Selection (by id) persists and the moved rows reappear in their new
    /// group still checked, so a chained batch action stays undoable. Only the
    /// control-bar refresh re-fetches (and drops acted-on rows).
    @discardableResult
    func setListName(_ items: [Item], to listName: String?) -> [Item] {
        var updated: [Item] = []
        for item in items {
            do {
                try store.setListName(id: item.id, to: listName)
                if let u = try store.fetch(id: item.id) { replaceInPlace(u); updated.append(u) }
            } catch {
                NSLog("IceboxModel: setListName failed for \(item.id): \(error)")
            }
        }
        regroupInPlace()
        return updated
    }

    /// Run a store mutation, then re-read the single row and swap it into
    /// `groups` in place (same position) so the row updates without the list
    /// jumping or dropping it. Returns the updated row so a caller holding its
    /// own copy (the reader) can refresh from it.
    @discardableResult
    private func mutate(_ item: Item, _ op: (String) throws -> Void) -> Item? {
        do {
            try op(item.id)
            if let updated = try store.fetch(id: item.id) {
                replaceInPlace(updated)
                return updated
            }
        } catch {
            NSLog("IceboxModel: action failed: \(error)")
        }
        return nil
    }

    /// The set form of `mutate`: apply `op` per id, re-read each row, swap it
    /// into `groups` in place (same position), and return the updated rows.
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
                NSLog("IceboxModel: batch action failed for \(item.id): \(error)")
            }
        }
        return updated
    }

    private func replaceInPlace(_ updated: Item) {
        for (g, group) in groups.enumerated() {
            if let i = group.items.firstIndex(where: { $0.id == updated.id }) {
                var items = group.items
                items[i] = updated
                groups[g] = IceboxGroup(listName: group.listName, items: items)
                return
            }
        }
    }

    /// Re-bucket the current snapshot's items (no store round-trip), so a
    /// structural batch op (a list change) moves rows between groups while
    /// retaining resolved / moved rows. Used by `setListName`.
    private func regroupInPlace() {
        groups = IceboxGrouping.groups(items: groups.flatMap(\.items))
    }

    private func load(spinner: Bool) {
        if spinner { isLoading = true } else { isWorking = true }
        do {
            groups = IceboxGrouping.groups(items: try store.fetchIceboxed())
        } catch {
            NSLog("IceboxModel: load failed: \(error)")
        }
        // Prune selection / focus to the rows that still exist (a refresh drops
        // resolved + moved rows), then seat focus on the first visible row when
        // it isn't already on a live row.
        let present = Set(groups.flatMap(\.items).map { $0.id })
        selectedIDs.formIntersection(present)
        if let f = focusedItemID, !present.contains(f) { focusedItemID = nil }
        if focusedItemID == nil {
            focusedItemID = IceboxNavigation.visibleIDs(groups, collapsed: collapsedLists).first
        }
        isLoading = false
        isWorking = false
    }
}
