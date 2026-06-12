import SwiftUI

/// One icebox item. Tapping the row body opens the reader. On hover, three
/// action buttons float right-aligned over a scrim; the slots stay fixed so
/// the layout doesn't shift, and the clicked button becomes Undo in place
/// while siblings that no longer apply are disabled (not removed):
///  - active:   [Done|Dismiss]   [Move to Today]    [⋮]
///  - resolved: [Undo]           [Move to Today ✗]  [⋮ ✗]   (struck/dimmed)
///  - moved:    [Done|Dismiss]   [Undo]             [⋮]     ("Moved to Today")
/// Done implicitly schedules today, so it disables Move + the kind menu;
/// a moved item can still be completed or reclassified. State is read from
/// the (locally-mutated) snapshot item, so an action's effect shows
/// immediately while the list keeps the row until refresh.
struct IceboxRow: View {
    let item: Item
    let onOpen: () -> Void

    @ObservedObject private var model = IceboxModel.shared
    @State private var isHovering = false

    private var isResolved: Bool { item.resolvedAt != nil }
    private var isMoved: Bool { item.resolvedAt == nil && item.iceboxedAt == nil }
    private var isFocused: Bool { model.focusedItemID == item.id }
    private var isSelected: Bool { model.selectedIDs.contains(item.id) }

    var body: some View {
        // The gutter (focus bar + checkbox) is a SIBLING of the tappable row
        // body, not nested inside it: rowContent puts the onOpen pointerButton
        // over its whole HStack, and that overlay would shadow the checkbox's
        // own tap. Splitting them keeps the two gestures independent.
        HStack(spacing: 0) {
            gutter
            rowContent
        }
        // Overlay (not a ZStack child) so the floating buttons never add to the
        // row's height — a hovered row stays the same size. Flush to the row's
        // trailing content edge: the outer .padding(.horizontal, 8) is the only
        // right inset, so the floating card sits 8pt from the list edge.
        .overlay(alignment: .trailing) { if isHovering { actions } }
        // Persistent selected shading, with the transient hover tint layered on.
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(isSelected ? 0.12 : 0))
        )
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(isHovering ? 0.10 : 0))
        )
        .padding(.horizontal, 8)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
    }

    /// Focus bar + checkbox. Kept OUTSIDE rowContent's `.opacity(resolved/moved)`
    /// so the selection affordance stays full-strength on a greyed row. The
    /// checkbox owns its own tap (toggle), distinct from the row body's open.
    private var gutter: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(isFocused ? Color.accentColor : Color.clear)
                .frame(width: 3)
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .pointerButton(onHoverChange: { _ in }, action: { model.toggleSelected(item.id) })
        }
        .padding(.leading, 6)
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            // Fixed-width leading column so the kind pills share a column and
            // every title starts at the same x, lining up vertically.
            KindBadge(item: item)
                .frame(width: 76, alignment: .leading)
            titleLine
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            Text(statusText)
                .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
        }
        .opacity(isResolved || isMoved ? 0.5 : 1)
        .padding(.vertical, 6).padding(.horizontal, 6)
        .contentShape(Rectangle())
        // Row body opens the reader; the action overlay sits above it.
        .pointerButton(onHoverChange: { _ in }, action: onOpen)
    }

    /// Gmail-style one-line content: the title, then a muted plain-text body
    /// preview, all truncated to the single title column.
    private var titleLine: Text {
        let title = Text(item.title).strikethrough(isResolved)
            .fontWeight(.semibold).foregroundStyle(.primary)
        if let preview = item.bodyPlainPreview {
            return title + Text("  \(preview)").foregroundStyle(.secondary)
        }
        return title
    }

    /// Right column under the title: the friendly iceboxed date, or the
    /// moved tag.
    private var statusText: String {
        if isMoved { return "Moved to Today" }
        guard let at = item.iceboxedAt else { return "" }
        return Self.dateFormatter.string(from: at)
    }

    private var actions: some View {
        // Shared with the actionable reader's control bar. The list row needs
        // no onChange callback — it re-renders from the model's regrouped
        // snapshot after a mutation.
        ItemActions(items: [item])
            // Scrim so the floating buttons stay legible over the title/date.
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(.regularMaterial)
            )
    }

    /// Friendly iceboxed date, e.g. "Jun 9".
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()
}
