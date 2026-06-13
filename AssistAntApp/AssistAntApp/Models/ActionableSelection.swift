import Foundation
import Combine

/// Selection + keyboard focus for an actionable list, by item id (survives
/// regrouping). Surface-agnostic: the owning model passes its current groups +
/// collapsed set; this owns no snapshot. Observed directly by the row, control
/// bar, and key monitor so they react to selection without re-rendering on
/// every snapshot change.
@MainActor
final class ActionableSelection: ObservableObject {
    /// A shared, never-mutated selection for surfaces with no batch selection
    /// (the Today sidebar): its rows read focus/selection as false and render no
    /// gutter, so this instance only satisfies the row's `@ObservedObject`.
    static let disabled = ActionableSelection()

    /// Rows selected for batch actions, by item id.
    @Published private(set) var selectedIDs: Set<String> = []
    /// The row receiving X / Enter (the focus bar), by item id. Distinct from
    /// selection: a row can be focused without being selected and vice-versa.
    @Published private(set) var focusedItemID: String?

    var hasSelection: Bool { !selectedIDs.isEmpty }

    /// The selected items in visible (top→bottom) order, for feeding the cluster.
    func selectedItems(in groups: [ActionableGroup], collapsed: Set<String>) -> [Item] {
        let order = ActionableListNavigation.visibleIDs(groups, collapsed: collapsed)
        let byID = Dictionary(
            uniqueKeysWithValues: groups.flatMap(\.items).map { ($0.id, $0) })
        return order.filter(selectedIDs.contains).compactMap { byID[$0] }
    }

    /// The currently focused item, for Enter-to-open.
    func focusedItem(in groups: [ActionableGroup]) -> Item? {
        guard let focusedItemID else { return nil }
        return groups.flatMap(\.items).first { $0.id == focusedItemID }
    }

    func toggleSelected(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }
    func clearSelection() { selectedIDs.removeAll() }            // *n
    func selectAll(in ids: [String]) { selectedIDs.formUnion(ids) }   // *a (host scopes)
    func focus(_ id: String?) { focusedItemID = id }
    func toggleSelectedFocused() { if let id = focusedItemID { toggleSelected(id) } }   // X
    func moveFocus(by delta: Int, order: [String]) {
        focusedItemID = ActionableListNavigation.step(from: focusedItemID, by: delta, in: order)
    }

    /// Prune to the rows that still exist after a (re)load, then seat focus on
    /// the first visible row when it isn't already on a live row.
    func reconcile(visible: [String], present: Set<String>) {
        selectedIDs.formIntersection(present)
        if let f = focusedItemID, !present.contains(f) { focusedItemID = nil }
        if focusedItemID == nil { focusedItemID = visible.first }
    }
}
