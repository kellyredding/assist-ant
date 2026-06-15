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
    /// Drop handling for this row's surface; `.disabled` on read-only contexts.
    var dropHandler: ActionableDropHandler = .disabled
    /// The group this row belongs to — for the drop delegate + insertion line.
    var groupID: String = ""
    var groupListName: String? = nil
    /// Schedule passes its day so a cross-day drop reschedules; nil elsewhere.
    var day: CivilDate? = nil

    enum Context { case icebox, schedule, today, trash }

    @State private var isHovering = false
    /// Anchors the hover tooltip to this row's live screen frame.
    @State private var tipAnchor = RowFrameAnchor()
    /// The live drag, for revealing the grip and drawing the insertion line.
    @ObservedObject private var drag = ItemDragSession.shared
    /// Measured row height, so the drop delegate can split top/bottom halves.
    @State private var rowHeight: CGFloat = 36

    private var isResolved: Bool { item.resolvedAt != nil }
    private var isIceboxed: Bool { item.iceboxedAt != nil }
    private var isDeleted: Bool { item.deletedAt != nil }
    private var isFocused: Bool { selection.focusedItemID == item.id }
    private var isSelected: Bool { selection.selectedIDs.contains(item.id) }
    /// Whether this surface shows the selection gutter (focus bar + checkbox).
    /// The Today sidebar drops it — its rows aren't batch-selectable.
    private var showsGutter: Bool { context != .today }
    /// Hover effects (tooltip, action cluster, tint) are suppressed while a drag
    /// is in flight so they don't fight the drag.
    private var showsHover: Bool { isHovering && !drag.isDragging }
    /// True when the row carries a future scheduled day (Today only): it has
    /// left today's set and is held, dimmed, until the next refresh.
    private var isScheduledFuture: Bool {
        guard let on = item.scheduledOn else { return false }
        return on > CivilDate.today
    }

    /// The payload stamped on `ItemDragSession` when this row's grip is dragged.
    private var dragPayload: ItemDragSession.Payload {
        ItemDragSession.Payload(
            id: item.id,
            surface: context,
            listName: item.actionableListName,
            kind: ItemType(rawValue: item.type) ?? .todo,
            day: context == .schedule ? day : nil,
            isResolved: isResolved)
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
            // The drag grip rides the leading edge — left of the checkbox on the
            // index surfaces, left of the kind badge on Today. A fixed column so
            // adding it never shifts layout on hover.
            ActionableDragHandle(item: item, payload: dragPayload, isRowHovering: showsHover)
            if showsGutter { gutter }
            rowContent
        }
        // Keyboard-focus bar: a row-height leading overlay rather than a flexible
        // sibling Rectangle. An overlay is handed the row's already-resolved
        // height, so the bar spans the full row identically on every surface —
        // the flexible sibling collapsed progressively in the Schedule's nested
        // day layout. Outside rowContent's dim opacity, so it stays full-strength
        // on a greyed row; gated to gutter surfaces (the Today sidebar has none).
        .overlay(alignment: .leading) {
            if showsGutter {
                Rectangle()
                    .fill(isFocused ? Color.accentColor : Color.clear)
                    .frame(width: 3)
            }
        }
        // Overlay (not a ZStack child) so the floating buttons never add to the
        // row's height — a hovered row stays the same size.
        .overlay(alignment: .trailing) { if showsHover { hoverCluster } }
        // Persistent selected shading, with the transient hover tint layered on.
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(isSelected ? 0.12 : 0))
        )
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(showsHover ? 0.10 : 0))
        )
        .background(FrameAnchorView(anchor: tipAnchor))
        // A small trailing inset gives the hover cluster + trailing status a
        // little breathing room from the list's right edge (matching the refresh
        // glyph above). The leading edge stays flush, so the focus bar runs to
        // the very edge and the title fills out to where the hover anchors.
        .padding(.trailing, 8)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
            if hovering && !drag.isDragging {
                ItemTooltipController.shared.requestShow(
                    item, anchor: tipAnchor, side: tooltipSide)
            } else {
                ItemTooltipController.shared.requestHide(tipAnchor)
            }
        }
        .onChange(of: drag.isDragging) { _, dragging in
            // Suppress hover (tooltip + cluster + tint) the moment a drag starts.
            if dragging {
                isHovering = false
                ItemTooltipController.shared.hideNow()
            }
        }
        .onDisappear { ItemTooltipController.shared.hideNow() }
        // Measure the row so the drop delegate can split top/bottom halves.
        .background(GeometryReader { proxy in
            Color.clear.onAppear { rowHeight = proxy.size.height }
        })
        // The insertion line: a 2pt accent rule on the edge a drop will land on.
        .overlay(alignment: .top) {
            if drag.indicator == ItemDragSession.Indicator(
                groupID: groupID, rowID: item.id, edge: .above) { insertionLine }
        }
        .overlay(alignment: .bottom) {
            if drag.indicator == ItemDragSession.Indicator(
                groupID: groupID, rowID: item.id, edge: .below) { insertionLine }
        }
        .onDrop(of: [.text], delegate: ItemDropDelegate(
            groupID: groupID, groupListName: groupListName, rowItem: item,
            rowHeight: rowHeight, day: day, handler: dropHandler))
    }

    /// The 2pt accent insertion line drawn at the row edge a drop will land on.
    private var insertionLine: some View {
        Rectangle().fill(Color.accentColor).frame(height: 2)
    }

    /// Today rows hang the tooltip to the right, into the main pane; the
    /// selectable surfaces (icebox, schedule) hang it left, over the sidebar.
    private var tooltipSide: ItemTooltipController.Side {
        context == .today ? .right : .left
    }

    /// Selection checkbox. The keyboard-focus bar is drawn as a separate
    /// row-height overlay (see `body`), so its height is the row's resolved
    /// height on every surface rather than a flexible fill that collapsed in the
    /// Schedule's nested day layout. The checkbox owns its own tap (toggle),
    /// distinct from the row body's open.
    private var gutter: some View {
        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .pointerButton(onHoverChange: { _ in }, action: { selection.toggleSelected(item.id) })
            .padding(.leading, 8)
    }

    private var rowContent: some View {
        HStack(spacing: 6) {
            // Fixed-width leading column so the kind pills share a column and
            // every title starts at the same x, lining up vertically — sized to
            // just fit the widest pill so the title sits close to the badge.
            KindBadge(item: item)
                .frame(width: 68, alignment: .leading)
            // The title fills the remaining width so it runs out to the same
            // right edge the hover cluster anchors to; the trailing status (only
            // when present) sits flush right after it.
            titleLine
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !statusText.isEmpty {
                Text(statusText)
                    .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
            }
        }
        .opacity(isDimmed ? 0.5 : 1)
        .padding(.vertical, 6)
        // No leading inset where the gutter already offsets the content (icebox /
        // schedule / trash); the gutter-less Today sidebar gets the list margin.
        .padding(.leading, showsGutter ? 0 : 8)
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
