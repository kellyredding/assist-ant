import SwiftUI
import UniformTypeIdentifiers

/// The index a dropped task lands at within the destination list (which
/// excludes the moved row): before/after the anchor row. Lives in the app
/// target (not `TaskReorder`) so the headless ItemsSmoke tool needn't see
/// `TaskDragSession`.
enum TaskReorderIndex {
    static func insertionIndex(in dest: [AgentTask], anchorID: String?,
                               edge: TaskDragSession.Edge) -> Int {
        guard let anchorID, let idx = dest.firstIndex(where: { $0.id == anchorID }) else {
            return dest.count
        }
        return edge == .above ? idx : idx + 1
    }
}

/// Per-row drop target for the Tasks list. Computes above/below from the
/// cursor's y vs. the row midpoint, publishes the live insertion indicator, and
/// performs the move via the bound closure. Simpler than `ItemDropDelegate` —
/// the flat list has no list/day/canDrop gating; any task may drop anywhere but
/// onto itself. `DropDelegate` runs on the main thread; `assumeIsolated` reaches
/// the main-actor session + model without hopping.
struct TaskDropDelegate: DropDelegate {
    let rowTask: AgentTask
    let rowHeight: CGFloat
    let onReorder: @MainActor (_ movedID: String, _ anchorID: String,
                               _ edge: TaskDragSession.Edge) -> Void

    private func edge(_ info: DropInfo) -> TaskDragSession.Edge {
        info.location.y < (rowHeight / 2) ? .above : .below
    }

    func validateDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            guard let p = TaskDragSession.shared.payload else { return false }
            return p.id != rowTask.id
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            guard let p = TaskDragSession.shared.payload, p.id != rowTask.id else {
                TaskDragSession.shared.indicator = nil
                return DropProposal(operation: .forbidden)
            }
            TaskDragSession.shared.indicator = .init(rowID: rowTask.id, edge: edge(info))
            return DropProposal(operation: .move)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            guard let p = TaskDragSession.shared.payload, p.id != rowTask.id else {
                TaskDragSession.shared.end()
                return false
            }
            onReorder(p.id, rowTask.id, edge(info))
            TaskDragSession.shared.end()
            return true
        }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated { TaskDragSession.shared.indicator = nil }
    }
}
