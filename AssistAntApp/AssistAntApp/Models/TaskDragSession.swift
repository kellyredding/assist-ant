import SwiftUI

/// The in-flight drag of a single task row. A shared singleton (like
/// `ItemDragSession`) observed by the grip, the drop delegate, and the
/// insertion line. The Tasks list is flat — no sub-lists — so a task drag needs
/// only the id (for self-drop rejection) and the name (for the floating chip),
/// and the indicator keys on row + edge alone.
///
/// Named `TaskDragSession` to avoid colliding with SwiftUI's `DragSession`.
@MainActor
final class TaskDragSession: ObservableObject {
    static let shared = TaskDragSession()

    /// Which side of the anchor row the drop lands on.
    enum Edge { case above, below }

    struct Payload: Equatable {
        let id: String
        let name: String   // for the floating drag chip
    }

    /// Where the insertion line draws: on `edge` of `rowID`.
    struct Indicator: Equatable {
        let rowID: String
        let edge: Edge
    }

    @Published private(set) var payload: Payload?
    @Published var indicator: Indicator?

    var isDragging: Bool { payload != nil }

    func begin(_ payload: Payload) { self.payload = payload }
    func end() { payload = nil; indicator = nil }
}
