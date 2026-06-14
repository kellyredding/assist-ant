import SwiftUI

/// One actionable item row. Tapping the body opens the reader; a leading gutter
/// (keyboard-focus bar + selection checkbox) sits to its left and the shared
/// `ItemActions` cluster (Resolve + Icebox slots) floats in on hover, so the
/// row holds no action logic of its own. State is read from the locally-mutated
/// snapshot item, so an action's effect shows immediately while the list keeps
/// the row until the next refresh: a resolved row is struck + dimmed, and a row
/// that has just left the icebox dims in place until it drops on refresh.
struct ActionableRow: View {
    let item: Item
    let onOpen: () -> Void
    /// The selectable surfaces (icebox, schedule) pass their selection; the
    /// Today sidebar passes nil — it has no gutter, no batch selection, and no
    /// keyboard chords, so focus/selection read as false.
    @ObservedObject var selection: ActionableSelection = .disabled
    let actions: ActionableActions
    /// The surface this row renders on; governs the gutter, which transient
    /// state dims the row, and what the trailing status reads.
    var context: Context = .icebox

    enum Context { case icebox, schedule, today, trash }

    @State private var isHovering = false
    /// Anchors the hover tooltip to this row's live screen frame.
    @State private var tipAnchor = RowFrameAnchor()

    private var isResolved: Bool { item.resolvedAt != nil }
    private var isIceboxed: Bool { item.iceboxedAt != nil }
    private var isDeleted: Bool { item.deletedAt != nil }
    private var isFocused: Bool { selection.focusedItemID == item.id }
    private var isSelected: Bool { selection.selectedIDs.contains(item.id) }
    /// Whether this surface shows the selection gutter (focus bar + checkbox).
    /// The Today sidebar drops it — its rows aren't batch-selectable.
    private var showsGutter: Bool { context != .today }
    /// True when the row carries a future scheduled day (Today only): it has
    /// left today's set and is held, dimmed, until the next refresh.
    private var isScheduledFuture: Bool {
        guard let on = item.scheduledOn else { return false }
        return on > CivilDate.today
    }

    /// Dim a row whose state has stepped out of its surface's resting set:
    /// resolved anywhere; in the icebox a row that just left the box; on the
    /// schedule a row just put into the box; in Today a row that has left today
    /// (iceboxed or rescheduled into the future). All drop on the next refresh.
    private var isDimmed: Bool {
        switch context {
        case .icebox:   return isResolved || isDeleted || !isIceboxed
        case .schedule: return isResolved || isDeleted || isIceboxed
        case .today:    return isResolved || isDeleted || isScheduledFuture || isIceboxed
        case .trash:    return !isDeleted   // only a held (put-back) row dims
        }
    }

    var body: some View {
        // The gutter (focus bar + checkbox) is a SIBLING of the tappable row
        // body, not nested inside it: rowContent puts the onOpen pointerButton
        // over its whole HStack, and that overlay would shadow the checkbox's
        // own tap. Splitting them keeps the two gestures independent.
        HStack(spacing: 0) {
            if showsGutter { gutter }
            rowContent
        }
        // Overlay (not a ZStack child) so the floating buttons never add to the
        // row's height — a hovered row stays the same size. Flush to the row's
        // trailing content edge: the outer .padding(.horizontal, 8) is the only
        // right inset, so the floating card sits 8pt from the list edge.
        .overlay(alignment: .trailing) { if isHovering { hoverCluster } }
        // Persistent selected shading, with the transient hover tint layered on.
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(isSelected ? 0.12 : 0))
        )
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(isHovering ? 0.10 : 0))
        )
        .background(FrameAnchorView(anchor: tipAnchor))
        .padding(.horizontal, 8)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                ItemTooltipController.shared.requestShow(
                    item, anchor: tipAnchor, side: tooltipSide)
            } else {
                ItemTooltipController.shared.requestHide(tipAnchor)
            }
        }
        .onDisappear { ItemTooltipController.shared.hideNow() }
    }

    /// Today rows hang the tooltip to the right, into the main pane; the
    /// selectable surfaces (icebox, schedule) hang it left, over the sidebar.
    private var tooltipSide: ItemTooltipController.Side {
        context == .today ? .right : .left
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
                .pointerButton(onHoverChange: { _ in }, action: { selection.toggleSelected(item.id) })
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
        .opacity(isDimmed ? 0.5 : 1)
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

    /// Trailing status column. In the icebox: the friendly iceboxed date, or
    /// the moved-out tag. On the schedule: empty normally (the day header gives
    /// the date), tagged only while transiently iceboxed. In Today: empty
    /// normally (the column carries the day), tagged while held — moved to the
    /// icebox or rescheduled into the future — until the next refresh drops it.
    private var statusText: String {
        switch context {
        case .icebox:
            if isDeleted { return "Moved to Trash" }
            if !isResolved && !isIceboxed { return "Moved to Today" }
            guard let at = item.iceboxedAt else { return "" }
            return Self.dateFormatter.string(from: at)
        case .schedule:
            if isDeleted { return "Moved to Trash" }
            return isIceboxed ? "Moved to Icebox" : ""
        case .today:
            if isDeleted { return "Moved to Trash" }
            if isIceboxed { return "Moved to Icebox" }
            if isScheduledFuture { return "Rescheduled" }
            return ""
        case .trash:
            if !isDeleted { return "Put back" }   // held until refresh
            guard let at = item.deletedAt else { return "" }
            return Self.dateFormatter.string(from: at)
        }
    }

    private var hoverCluster: some View {
        // Shared with the reader's control bar. The list row needs no onChange
        // callback — it re-renders from the model's regrouped snapshot. Today
        // renders the slots as glyphs (`glyphs:`) to fit the narrow column. The
        // Trash surface swaps in the scaled-back TrashActions cluster.
        Group {
            if context == .trash {
                TrashActions(items: [item], actions: actions)
            } else {
                ItemActions(items: [item], actions: actions, glyphs: context == .today)
            }
        }
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
