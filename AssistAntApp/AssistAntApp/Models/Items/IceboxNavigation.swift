import Foundation

/// Pure helpers over the grouped icebox snapshot for keyboard navigation and
/// selection. No SwiftUI, no model state — operate on groups + the collapsed
/// set so ItemsSmoke can exercise them.
enum IceboxNavigation {
    /// The visible item ids top→bottom: every group's items in order, skipping
    /// the items inside collapsed named groups (the no-list group is never
    /// collapsible). This is the J/K traversal order.
    static func visibleIDs(_ groups: [IceboxGroup], collapsed: Set<String>) -> [String] {
        groups.flatMap { group -> [String] in
            if let name = group.listName, collapsed.contains(name) { return [] }
            return group.items.map { $0.id }
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

    /// The ids of every item in the group that contains `focused` — the `*a`
    /// target. Empty when nothing is focused.
    static func idsInGroup(of focused: String?, _ groups: [IceboxGroup]) -> [String] {
        guard let focused else { return [] }
        for group in groups where group.items.contains(where: { $0.id == focused }) {
            return group.items.map { $0.id }
        }
        return []
    }
}
