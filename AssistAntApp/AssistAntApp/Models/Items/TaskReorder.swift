import Foundation

/// Applies a drag-reorder to the flat Tasks list: one `setPosition`, or a
/// `setPositions` batch that renumbers the list with the moved row inserted at
/// `index`. Mirrors `ItemReorder`, reusing `ItemPositionRank` for the ranking
/// math (it's generic over `[Double?]`). Pure + smoke-testable (Foundation +
/// the store; no AppKit, no drag session).
enum TaskReorder {
    static func apply(store: TasksStore, destination ordered: [AgentTask],
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
