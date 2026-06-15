import SwiftUI
import UniformTypeIdentifiers

extension ItemReorder {
    /// The index a dropped item lands at within `dest` (which excludes the moved
    /// item): before/after the anchor row, or the end when there's no anchor.
    /// Lives in the app target (not ItemPositionRank) so the headless ItemsSmoke
    /// tool needn't see `ItemDragSession`.
    static func insertionIndex(in dest: [Item], anchorID: String?,
                               edge: ItemDragSession.Edge) -> Int {
        guard let anchorID, let idx = dest.firstIndex(where: { $0.id == anchorID }) else {
            return dest.count
        }
        return edge == .above ? idx : idx + 1
    }
}

/// The mutation a drop performs, bound by the host model (mirrors
/// `ActionableActions`). The model knows its own surface; the delegate supplies
/// the destination list, the anchor row + edge, and (Schedule) the day.
/// `anchorID == nil` appends to the end of the destination list.
struct ActionableDropHandler {
    var canDrop: @MainActor (_ payload: ItemDragSession.Payload, _ intoList: String?, _ day: CivilDate?) -> Bool
    var performDrop: @MainActor (_ payload: ItemDragSession.Payload, _ intoList: String?, _ anchorID: String?, _ edge: ItemDragSession.Edge, _ day: CivilDate?) -> Void

    static let disabled = ActionableDropHandler(
        canDrop: { _, _, _ in false },
        performDrop: { _, _, _, _, _ in })
}

/// Per-row drop target. Computes before/after from the cursor's y vs. the row
/// midpoint, publishes the live insertion indicator, gates with `canDrop`, and
/// performs the move via the bound handler. SwiftUI calls `DropDelegate` on the
/// main thread; `MainActor.assumeIsolated` lets these reach the main-actor
/// session + handler without hopping.
struct ItemDropDelegate: DropDelegate {
    let groupID: String
    let groupListName: String?
    let rowItem: Item
    let rowHeight: CGFloat
    let day: CivilDate?
    let handler: ActionableDropHandler

    private func edge(_ info: DropInfo) -> ItemDragSession.Edge {
        info.location.y < (rowHeight / 2) ? .above : .below
    }

    func validateDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            guard let p = ItemDragSession.shared.payload, p.id != rowItem.id else { return false }
            return handler.canDrop(p, groupListName, day)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            guard let p = ItemDragSession.shared.payload, p.id != rowItem.id,
                  handler.canDrop(p, groupListName, day) else {
                ItemDragSession.shared.indicator = nil
                return DropProposal(operation: .forbidden)
            }
            ItemDragSession.shared.indicator = .init(
                groupID: groupID, rowID: rowItem.id, edge: edge(info))
            return DropProposal(operation: .move)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            guard let p = ItemDragSession.shared.payload, p.id != rowItem.id else {
                ItemDragSession.shared.end()
                return false
            }
            handler.performDrop(p, groupListName, rowItem.id, edge(info), day)
            ItemDragSession.shared.end()
            return true
        }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated { ItemDragSession.shared.indicator = nil }
    }
}

/// Drop target that appends to a list — used by the Schedule absent-list
/// placeholder (drop a row onto a day that doesn't yet carry its list) and any
/// "end of list" zone. `anchorID == nil` tells the handler to append.
struct ListAppendDropDelegate: DropDelegate {
    let listName: String?
    let day: CivilDate?
    let handler: ActionableDropHandler

    func validateDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            guard let p = ItemDragSession.shared.payload else { return false }
            return handler.canDrop(p, listName, day)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            guard let p = ItemDragSession.shared.payload, handler.canDrop(p, listName, day) else {
                return DropProposal(operation: .forbidden)
            }
            return DropProposal(operation: .move)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            guard let p = ItemDragSession.shared.payload else {
                ItemDragSession.shared.end()
                return false
            }
            handler.performDrop(p, listName, nil, .below, day)
            ItemDragSession.shared.end()
            return true
        }
    }
}

/// The Schedule placeholder shown at the base of a day during a drag when that
/// day doesn't yet carry the dragged item's list. Dropping on it keeps the list
/// name and reschedules the item onto the day.
struct AbsentListDropSlot: View {
    let listName: String?
    /// Schedule passes the target day; Today passes nil (no reschedule).
    let day: CivilDate?
    let handler: ActionableDropHandler

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.caption2).foregroundStyle(.secondary)
            Text(listName.map { "Drop to keep \u{201C}\($0)\u{201D}" } ?? "Drop here (no list)")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    Color.accentColor.opacity(0.5),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .padding(.bottom, 6)
        .onDrop(of: [.text],
                delegate: ListAppendDropDelegate(listName: listName, day: day, handler: handler))
    }
}
