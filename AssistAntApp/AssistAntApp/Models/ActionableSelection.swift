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
    func deselect(_ ids: [String]) { selectedIDs.subtract(ids) } // after a batch list move
    func selectAll(in ids: [String]) { selectedIDs.formUnion(ids) }   // *a (host scopes)
    func focus(_ id: String?) { focusedItemID = id }

    /// X — toggle the focused row, but only when focus sits on a row that is
    /// actually on screen.
    ///
    /// The visible set is a parameter rather than something inferred from
    /// `focusedItemID` alone, because a query or filter change can strand focus
    /// on a row that no longer renders. Toggling that id would seed a selection
    /// nothing can display: the count climbs while no checkbox ticks, and every
    /// batch action — each of which scopes itself to visible rows — then finds
    /// nothing to act on. Refusing is the honest answer, since a keystroke that
    /// cannot show its own effect has not selected anything the user can see.
    func toggleSelectedFocused(in visible: [String]) {
        guard let id = focusedItemID, visible.contains(id) else { return }
        toggleSelected(id)
    }

    func moveFocus(by delta: Int, order: [String]) {
        focusedItemID = ActionableListNavigation.step(from: focusedItemID, by: delta, in: order)
    }

    /// Seat focus on a visible row: leave it alone when it already sits on one,
    /// otherwise take the first (nil when there are no rows at all).
    ///
    /// Idempotent, so a host may call it on arrival and on every change to the
    /// visible set without ever moving a focus the user placed deliberately.
    /// That is what makes it safe to call from more places than a reload —
    /// filtering a list changes which rows exist as surely as reloading it does.
    func ensureFocus(in visible: [String]) {
        if let f = focusedItemID, visible.contains(f) { return }
        focusedItemID = visible.first
    }

    /// Prune to the rows that still exist after a (re)load, then reseat focus.
    func reconcile(visible: [String], present: Set<String>) {
        selectedIDs.formIntersection(present)
        ensureFocus(in: visible)
    }
}
