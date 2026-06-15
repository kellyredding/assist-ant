import Foundation

/// Pure ranking math for drag-reorder. Given a destination group's positions in
/// rendered order (excluding the moved item) and a target insertion index,
/// produce either one fractional position for the moved item, or a full-group
/// renormalization when the neighbors can't supply a clean midpoint — an
/// unranked (nil) neighbor, or two adjacent ranks that have run out of room
/// between them.
///
/// The common path is `.single` (one write per drop). `.renormalize` fires the
/// first time an item is dropped into a still-unranked group (everything starts
/// nil), assigning evenly spaced integers so subsequent drops are midpoints.
enum ItemPositionRank {
    /// Even spacing used when (re)numbering a whole group.
    static let step: Double = 1024
    /// Two ranks closer than this are treated as collided → renormalize.
    static let epsilon: Double = 1e-6

    enum Result: Equatable {
        /// Write just the moved item's new position.
        case single(Double)
        /// Renormalize the destination group: evenly spaced ranks, mapped onto
        /// the post-drop item order by the caller.
        case renormalize([Double])
    }

    /// `positions` is the destination group's positions in rendered order,
    /// EXCLUDING the moved item. `index` is where the moved item lands
    /// (`0...positions.count`).
    static func place(insertingAt index: Int, into positions: [Double?]) -> Result {
        let count = positions.count
        let clamped = max(0, min(index, count))
        let hasPrev = clamped > 0
        let hasNext = clamped < count
        let prev: Double? = hasPrev ? positions[clamped - 1] : nil
        let next: Double? = hasNext ? positions[clamped] : nil

        // An existing neighbor with no rank means the group's order isn't fully
        // expressed by `position` yet — renumber it so the drop is unambiguous.
        if hasPrev && prev == nil { return renormalized(count: count + 1) }
        if hasNext && next == nil { return renormalized(count: count + 1) }

        switch (prev, next) {
        case let (p?, n?):
            let mid = (p + n) / 2
            if (mid - p) <= epsilon || (n - mid) <= epsilon {
                return renormalized(count: count + 1)
            }
            return .single(mid)
        case let (p?, nil):
            return .single(p + step)   // append after the last ranked item
        case let (nil, n?):
            return .single(n - step)   // insert before the first ranked item
        case (nil, nil):
            return .single(0)          // empty group
        }
    }

    static func renormalized(count: Int) -> Result {
        .renormalize((0..<count).map { Double($0) * step })
    }
}

/// Applies a computed rank to the store: either one `setPosition`, or a
/// `setPositions` batch that renumbers the destination group with the moved
/// item inserted at `index`. Shared by every surface's drop handler.
enum ItemReorder {
    static func apply(store: ItemStore, destination ordered: [Item],
                      movedID: String, insertAt index: Int) {
        let clamped = max(0, min(index, ordered.count))
        let positions = ordered.map { $0.position }
        switch ItemPositionRank.place(insertingAt: clamped, into: positions) {
        case .single(let p):
            try? store.setPosition(id: movedID, to: p)
        case .renormalize(let ranks):
            var ids = ordered.map { $0.id }
            ids.insert(movedID, at: min(clamped, ids.count))
            var map: [String: Double] = [:]
            for (id, rank) in zip(ids, ranks) { map[id] = rank }
            try? store.setPositions(map)
        }
    }
}
