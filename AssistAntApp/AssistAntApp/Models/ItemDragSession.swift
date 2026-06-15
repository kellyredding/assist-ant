import SwiftUI

/// The in-flight drag of a single actionable item. A shared singleton (like the
/// pane models) so the drag handle, the drop delegates, the insertion line, and
/// the Schedule absent-list placeholder all observe one source of truth without
/// environment plumbing. Every drag is in-process, so the payload metadata is
/// read here on drop — the NSItemProvider only needs to carry the id to make
/// the drag/drop machinery fire.
///
/// Named `ItemDragSession` to avoid colliding with SwiftUI's own `DragSession`.
@MainActor
final class ItemDragSession: ObservableObject {
    static let shared = ItemDragSession()

    /// Which side of the anchor row the drop lands on.
    enum Edge { case above, below }

    /// Everything a drop needs to know about the dragged item, captured at drag
    /// start so a drop target can validate (surface equality, past-day gate) and
    /// the Schedule placeholder can render for the dragged list.
    struct Payload: Equatable {
        let id: String
        let surface: ActionableRow.Context
        let listName: String?
        let kind: ItemType
        let day: CivilDate?       // schedule source day; nil elsewhere
        let isResolved: Bool
    }

    /// Where the insertion line draws: on `edge` of `rowID` within `groupID`.
    struct Indicator: Equatable {
        let groupID: String
        let rowID: String
        let edge: Edge
    }

    @Published private(set) var payload: Payload?
    @Published var indicator: Indicator?

    var isDragging: Bool { payload != nil }

    func begin(_ payload: Payload) { self.payload = payload }
    func end() { payload = nil; indicator = nil }
}
