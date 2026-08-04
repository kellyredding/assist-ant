import Foundation

/// A collapsible group of rows addressed by id — all the keyboard needs to walk
/// a grouped list, and deliberately nothing about what a row is.
///
/// Two group types conform: the actionable lists' groups hold items, and the
/// scratch feed's hold rows that pair a note with the offsets its query matched.
/// Traversal, `*a` scoping, and the collapse rule are identical for both, and
/// the differences between them are all below this line — so they are stated
/// once here rather than reproduced per surface, where they drifted.
protocol ListGroup {
    /// Stable collapse and ForEach key: the list name for a named group, a
    /// reserved sentinel for the group with no name.
    var id: String { get }
    /// This group's row ids, in display order.
    var memberIDs: [String] { get }
}

/// Pure helpers over a grouped snapshot for keyboard navigation and selection.
/// No SwiftUI, no model state — operate on groups + the collapsed set so
/// ItemsSmoke can exercise them.
///
/// Named for the actionable lists it was written for and kept that way now that
/// the scratch feed shares it, following `ActionableSelection`, which scratch
/// already reuses under the same prefix.
enum ActionableListNavigation {
    /// The visible row ids top→bottom: every group's rows in order, skipping the
    /// rows inside any collapsed group — named OR the no-name group, keyed by the
    /// group's id. This is the J/K traversal order.
    static func visibleIDs<G: ListGroup>(
        _ groups: [G], collapsed: Set<String>
    ) -> [String] {
        groups.flatMap { group -> [String] in
            if collapsed.contains(group.id) { return [] }
            return group.memberIDs
        }
    }

    /// The id one step from `current` in `order` (`delta` = +1 down / -1 up),
    /// clamped at the ends (no wrap). Nil `current` → the first/last visible id.
    static func step(from current: String?, by delta: Int, in order: [String]) -> String? {
        guard !order.isEmpty else { return nil }
        guard let current, let i = order.firstIndex(of: current) else {
            return delta >= 0 ? order.first : order.last
        }
        let j = max(0, min(order.count - 1, i + delta))
        return order[j]
    }

    /// The ids of every row in the group that contains `focused` — the `*a`
    /// target. Empty when nothing is focused, and empty when focus sits inside a
    /// collapsed group: `*a` may not seed a selection no row can show, which is
    /// the refusal `ActionableSelection.toggleSelectedFocused` already makes for
    /// `x`. Without it the count climbs over rows the batch cluster — which
    /// scopes itself to visible rows — then finds nothing to act on.
    static func idsInGroup<G: ListGroup>(
        of focused: String?, _ groups: [G], collapsed: Set<String>
    ) -> [String] {
        guard let focused else { return [] }
        for group in groups {
            let ids = group.memberIDs
            guard ids.contains(focused) else { continue }
            return collapsed.contains(group.id) ? [] : ids
        }
        return []
    }
}
