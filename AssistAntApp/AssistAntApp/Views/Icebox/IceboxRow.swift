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

    @State private var isHovering = false

    private var isResolved: Bool { item.resolvedAt != nil }
    private var isMoved: Bool { item.resolvedAt == nil && item.iceboxedAt == nil }

    var body: some View {
        rowContent
            // Overlay (not a ZStack child) so the floating buttons never add
            // to the row's height — a hovered row stays the same size.
            .overlay(alignment: .trailing) {
                // Flush to the row's trailing content edge — the outer
                // .padding(.horizontal, 8) below is the only right inset, so
                // the floating card sits 8pt from the list edge with no extra
                // gap stacked on top of it.
                if isHovering { actions }
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(isHovering ? 0.10 : 0))
            )
            .padding(.horizontal, 8)
            .animation(.easeInOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
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
