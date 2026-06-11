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

    func complete(_ item: Item) { mutate(item) { try store.completeActionable(id: $0) } }
    func reopen(_ item: Item) { mutate(item) { try store.reopenActionable(id: $0) } }
    func moveToToday(_ item: Item) { mutate(item) { try store.moveToToday(id: $0) } }
    func reIcebox(_ item: Item) { mutate(item) { try store.setIceboxed(id: $0, true) } }
    func reclassify(_ item: Item, to type: ItemType) {
        mutate(item) { try store.reclassify(id: $0, to: type) }
    }

    /// Run a store mutation, then re-read the single row and swap it into
    /// `groups` in place (same position) so the row updates without the list
    /// jumping or dropping it.
    private func mutate(_ item: Item, _ op: (String) throws -> Void) {
        do {
            try op(item.id)
            if let updated = try store.fetch(id: item.id) {
                replaceInPlace(updated)
            }
        } catch {
            NSLog("IceboxModel: action failed: \(error)")
        }
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
