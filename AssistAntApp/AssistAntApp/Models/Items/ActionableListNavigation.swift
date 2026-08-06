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

    /// The id of the FIRST row of the group one step from the group holding
    /// `focused` (`delta` = +1 down / -1 up), clamped at the ends. Nil only when
    /// no group on the surface has a row to land on.
    ///
    /// ⌘J/⌘K, the rung above `step`'s j/k: same currency — a row id the caller
    /// focuses — and the same clamp, so a jump off the last group hands back
    /// `focused` untouched rather than wrapping to the top. Clamping to the
    /// current group's own first row was the alternative and is wrong by
    /// direction: at the bottom of the list it would answer a downward keystroke
    /// by moving focus up. Both directions land on the target group's first row,
    /// never the group-above's last, so ⌘K then ⌘J returns to where it started.
    /// Only the sign of `delta` is read; one sublist per press is the whole
    /// gesture, and the parameter is spelled like `step`'s so both rungs read the
    /// same at a call site.
    ///
    /// A folded group is not a destination. It renders a header and zero rows, so
    /// there is no row to focus, and landing "on" it would leave the focus bar
    /// invisible while the next j walked away from somewhere the user was never
    /// shown. Folded groups are stepped straight past in both directions — which
    /// is also what lets a jump rescue focus OUT of a fold, the one keystroke that
    /// can, since toggling a fold reseats no focus. An empty group is unlandable
    /// for the same reason; no grouping here emits one, but leaving it in the
    /// candidate set would answer "nowhere to go" instead of stepping past it, and
    /// excluding it is what makes a nil return mean only one thing.
    ///
    /// Finds the current group POSITIONALLY, never by `group.id`. The Schedule
    /// flattens its days into one array and a group's id is its list name, so
    /// "Opex" is a different group on every day that carries an Opex item;
    /// matching on id resolves every Opex row to the first day's group and walks
    /// off from there — silently, and only on that one surface. Scanning
    /// `memberIDs` is exact for the reason `idsInGroup` is exact: a row id occurs
    /// in at most one group, each item bucketing to exactly one day. That is the
    /// invariant both helpers now rest on, and if a surface ever rendered one item
    /// in two groups, `*a` would mis-scope and this would leave from the wrong
    /// day. Collapse is still read by id, which is right for the same reason the
    /// ids repeat — folding a list folds it on every day. Crossing a day boundary,
    /// the last sublist of Tuesday to the first of Wednesday, is the intended
    /// consequence; a day with no actionables contributes no groups and is skipped
    /// without a special case.
    ///
    /// With nothing focused — or a focus no group holds, a stale id a filter or
    /// reload left behind, which is the same state here since neither yields a
    /// current group — falls to the near end in the direction of travel, as `step`
    /// does: the topmost landable group going down, the bottommost going up.
    /// Landing on that group's FIRST row either way, because where inside a group
    /// a jump lands is not a thing direction gets to change.
    static func stepGroup<G: ListGroup>(
        from focused: String?, by delta: Int, _ groups: [G],
        collapsed: Set<String>
    ) -> String? {
        // Landable groups, each carrying its position in `groups` — the position
        // is the whole point, since the id is not unique on the Schedule.
        let landable = groups.enumerated().filter {
            !collapsed.contains($0.element.id) && !$0.element.memberIDs.isEmpty
        }
        guard let top = landable.first, let bottom = landable.last
        else { return nil }
        guard let focused,
              let here = groups.firstIndex(
                  where: { $0.memberIDs.contains(focused) }
              )
        else { return (delta >= 0 ? top : bottom).element.memberIDs.first }
        let target = delta >= 0
            ? landable.first { $0.offset > here }
            : landable.last { $0.offset < here }
        return target?.element.memberIDs.first ?? focused   // no neighbour → clamp
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
