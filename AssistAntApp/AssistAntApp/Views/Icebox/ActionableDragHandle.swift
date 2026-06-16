import SwiftUI
import AppKit

/// The drag grip on an actionable row's leading edge — a thin wrapper over the
/// shared `DragGripView`, wiring the item drag session and an item-shaped
/// floating chip. The grip's AppKit machinery (cursor, NSDraggingSource, the
/// floating preview) lives in `DragGrip.swift` and is shared with the task rows.
/// The drop side stays SwiftUI (`ItemDropDelegate`), reading the payload from
/// `ItemDragSession`.
struct ActionableDragHandle: View {
    let item: Item
    let payload: ItemDragSession.Payload
    let isRowHovering: Bool

    /// The grip column width — sized so the bars clear the 3pt focus-bar overlay
    /// and the checkbox/caret below line up with it (see ActionableListSection's
    /// matching header inset).
    static let columnWidth: CGFloat = 22

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        DragGripView(
            dragID: item.id,
            isRowHovering: isRowHovering,
            onBegin: { screenPoint in
                ItemDragSession.shared.begin(payload)
                DragPreviewPanel.shared.show(
                    DragRowPreview(item: item, isDark: scheme == .dark),
                    isDark: scheme == .dark, at: screenPoint)
            },
            onMoved: { screenPoint in DragPreviewPanel.shared.move(to: screenPoint) },
            onEnd: { ItemDragSession.shared.end(); DragPreviewPanel.shared.hide() })
        .frame(width: Self.columnWidth, height: 20)
        .accessibilityLabel("Reorder")
    }
}

/// A compact, lifted row chip (badge + title) shown under the cursor while
/// dragging an item. Hosted in the floating `DragPreviewPanel`. Concrete
/// theme-matched background so it reads in dark mode.
private struct DragRowPreview: View {
    let item: Item
    let isDark: Bool
    var body: some View {
        HStack(spacing: 8) {
            KindBadge(item: item)
            Text(item.title)
                .font(.callout).fontWeight(.semibold)
                .lineLimit(1).truncationMode(.tail)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(width: dragPreviewSize.width, height: dragPreviewSize.height, alignment: .leading)
        .background(isDark ? Color(white: 0.16) : Color(white: 0.98))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(isDark ? 0.18 : 0.12))
        )
    }
}
