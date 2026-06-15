import Foundation
import Combine

/// Drives the Trash tab. Snapshot/refresh like IceboxModel: the list re-fetches
/// only on activation and the refresh glyph, never live. Row actions mutate the
/// in-memory snapshot in place (so a row's appearance changes without the list
/// re-sorting or dropping it), letting an accidental Put back be undone until
/// the next refresh. The displayed set is every soft-deleted actionable
/// (`fetchTrashed`), newest-deleted first, grouped by list — including Linear
/// orphans retired by sync (their Put back is disabled; sync owns them).
@MainActor
final class TrashModel: ObservableObject {
    static let shared = TrashModel()

    @Published private(set) var groups: [ActionableGroup] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    /// Collapsed named lists (by list name). In-memory for the session;
    /// survives tab switches (singleton) but not relaunch.
    @Published private(set) var collapsedLists: Set<String> = []
    /// Selection + keyboard focus for the list, by item id. A separate
    /// observable so the row, control bar, and key monitor observe it without
    /// re-rendering on every snapshot change.
    let selection = ActionableSelection()

    private let store: ItemStore
    private var hasActivatedOnce = false

    init(store: ItemStore = GRDBItemStore.shared) {
        self.store = store
        // A delete from any other surface (or a sync reconcile that retires an
        // orphan) changes the trashed set; refresh when one lands.
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

    /// Control-bar refresh glyph. Re-fetches and regroups, dropping put-back
    /// rows (a row whose tombstone was cleared is excluded by fetchTrashed).
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

    // MARK: - Shared action API (bound to the snapshot mutations below)

    /// The cluster's actions, bound to this model's in-place snapshot mutations,
    /// so `TrashActions` (row hover, reader, batch bar) drives the trash without
    /// referencing this model directly. Put back is the live verb; the rest are
    /// supplied because `ActionableActions` requires them (kind/list back the
    /// trimmed ⋮; the others are unused on this surface).
    var actions: ActionableActions {
        ActionableActions(
            complete: { self.complete($0) },
            reopen: { self.reopen($0) },
            moveToIcebox: { self.moveToIcebox($0) },
            removeFromIcebox: { self.removeFromIcebox($0) },
            reclassify: { self.reclassify($0, to: $1) },
            setListName: { self.setListName($0, to: $1) },
            delete: { self.delete($0) },
            putBack: { self.putBack($0) })
    }

    // MARK: - Drag-and-drop

    /// Drop handling bound to this surface. Trash accepts only items dragged
    /// from the Trash; a drop sets the list (when it changed) and the manual
    /// position among the destination neighbors.
    var dropHandler: ActionableDropHandler {
        ActionableDropHandler(
            canDrop: { payload, _, _ in payload.surface == .trash },
            performDrop: { [weak self] payload, list, anchorID, edge, _ in
                self?.performDrop(payload, intoList: list, anchor: anchorID, edge: edge)
            })
    }

    private func performDrop(_ payload: ItemDragSession.Payload,
                             intoList list: String?, anchor anchorID: String?,
                             edge: ItemDragSession.Edge) {
        guard let moved = item(forID: payload.id) else { return }
        let dest = orderedItems(inList: list).filter { $0.id != payload.id }
        let insertIdx = ItemReorder.insertionIndex(in: dest, anchorID: anchorID, edge: edge)
        if moved.actionableListName != list {
            try? store.setListName(id: payload.id, to: list)
        }
        ItemReorder.apply(store: store, destination: dest, movedID: payload.id, insertAt: insertIdx)
        ActionableSnapshots.refresh()
    }

    private func item(forID id: String) -> Item? {
        for group in groups {
            if let found = group.items.first(where: { $0.id == id }) { return found }
        }
        return nil
    }

    private func orderedItems(inList list: String?) -> [Item] {
        groups.first(where: { $0.listName == list })?.items ?? []
    }

    // MARK: - Row actions (mutate store + snapshot, no re-fetch)

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
    func delete(_ items: [Item]) -> [Item] {
        mutateMany(items) { try store.softDelete(id: $0) }
    }
    @discardableResult
    func putBack(_ items: [Item]) -> [Item] {
        mutateMany(items) { try store.undelete(id: $0) }
    }
    @discardableResult
    func reclassify(_ items: [Item], to type: ItemType) -> [Item] {
        mutateMany(items) { try store.reclassify(id: $0, to: type) }
    }

    /// Save an edited title + body for one item — kept for parity with the other
    /// host models, though trashed items open read-only so this never fires.
    @discardableResult
    func setTitleAndBody(_ item: Item, title: String, body: String?) -> Item? {
        mutate(item) { try store.setTitleAndBody(id: $0, title: title, body: body) }
    }

    /// Distinct list names in use, for the list-editor combobox suggestions.
    func knownListNames() -> [String] {
        (try? store.knownListNames()) ?? []
    }

    /// Set or clear the list name for a set, then regroup in place (a list
    /// change is structural — items move between groups), mirroring IceboxModel.
    @discardableResult
    func setListName(_ items: [Item], to listName: String?) -> [Item] {
        var updated: [Item] = []
        for item in items {
            do {
                try store.setListName(id: item.id, to: listName)
                if let u = try store.fetch(id: item.id) { replaceInPlace(u); updated.append(u) }
            } catch {
                NSLog("TrashModel: setListName failed for \(item.id): \(error)")
            }
        }
        regroupInPlace()
        if !updated.isEmpty { ActionableSnapshots.refresh(except: .trash) }
        return updated
    }

    @discardableResult
    private func mutate(_ item: Item, _ op: (String) throws -> Void) -> Item? {
        do {
            try op(item.id)
            if let updated = try store.fetch(id: item.id) {
                replaceInPlace(updated)
                ActionableSnapshots.refresh(except: .trash)
                return updated
            }
        } catch {
            NSLog("TrashModel: action failed: \(error)")
        }
        return nil
    }

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
                NSLog("TrashModel: batch action failed for \(item.id): \(error)")
            }
        }
        if !updated.isEmpty { ActionableSnapshots.refresh(except: .trash) }
        return updated
    }

    private func replaceInPlace(_ updated: Item) {
        for (g, group) in groups.enumerated() {
            if let i = group.items.firstIndex(where: { $0.id == updated.id }) {
                var items = group.items
                items[i] = updated
                groups[g] = ActionableGroup(listName: group.listName, items: items)
                return
            }
        }
    }

    private func regroupInPlace() {
        groups = ActionableGrouping.groups(items: groups.flatMap(\.items))
    }

    private func load(spinner: Bool) {
        if spinner { isLoading = true } else { isWorking = true }
        do {
            groups = ActionableGrouping.groups(items: try store.fetchTrashed())
        } catch {
            NSLog("TrashModel: load failed: \(error)")
        }
        // Prune selection / focus to the rows that still exist (a refresh drops
        // put-back rows), then seat focus on the first visible row.
        selection.reconcile(
            visible: ActionableListNavigation.visibleIDs(groups, collapsed: collapsedLists),
            present: Set(groups.flatMap(\.items).map { $0.id }))
        isLoading = false
        isWorking = false
    }
}
