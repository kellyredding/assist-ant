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

    // MARK: - Row actions (mutate store + snapshot, no re-fetch)

    @discardableResult
    func complete(_ item: Item) -> Item? { mutate(item) { try store.completeActionable(id: $0) } }
    @discardableResult
    func reopen(_ item: Item) -> Item? { mutate(item) { try store.reopenActionable(id: $0) } }
    @discardableResult
    func moveToToday(_ item: Item) -> Item? { mutate(item) { try store.moveToToday(id: $0) } }
    @discardableResult
    func reIcebox(_ item: Item) -> Item? { mutate(item) { try store.setIceboxed(id: $0, true) } }
    @discardableResult
    func reclassify(_ item: Item, to type: ItemType) -> Item? {
        mutate(item) { try store.reclassify(id: $0, to: type) }
    }
    /// Save an edited title + body. Not structural (grouping is by list name),
    /// so the row swaps in place — the list-row title and body preview refresh
    /// with it.
    @discardableResult
    func setTitleAndBody(_ item: Item, title: String, body: String?) -> Item? {
        mutate(item) { try store.setTitleAndBody(id: $0, title: title, body: body) }
    }

    /// Distinct list names in use, for the list-editor combobox suggestions.
    func knownListNames() -> [String] {
        (try? store.knownListNames()) ?? []
    }

    /// Set or clear an item's list name, then regroup. A list change is
    /// structural — the item moves to a different group — so unlike resolve /
    /// move this re-reads the snapshot rather than swapping the row in place.
    /// Returns the updated item so the reader can refresh from it.
    @discardableResult
    func setListName(_ item: Item, to listName: String?) -> Item? {
        do {
            try store.setListName(id: item.id, to: listName)
            let updated = try store.fetch(id: item.id)
            load(spinner: false)
            return updated
        } catch {
            NSLog("IceboxModel: setListName failed: \(error)")
            return nil
        }
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

    private func load(spinner: Bool) {
        if spinner { isLoading = true } else { isWorking = true }
        do {
            groups = IceboxGrouping.groups(items: try store.fetchIceboxed())
        } catch {
            NSLog("IceboxModel: load failed: \(error)")
        }
        isLoading = false
        isWorking = false
    }
}
