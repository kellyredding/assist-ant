import SwiftUI

/// One list group in the scratch feed: a chevron header that folds the group
/// away, then its notes. A named list shows its name; the no-list group shows
/// `UnnamedGroupChip` in the name's slot and sorts first. Collapse is keyed by
/// the group's id, so a named list and the no-list group fold through one
/// mechanism and the sentinel never enters the real list-name space.
///
/// A sibling of `ActionableListSection` rather than a use of it. That view is
/// typed on `ActionableGroup` and renders `ActionableRow`s, and everything it
/// requires — an actions cluster, an open handler, a drop handler, a day — a
/// note does not have: it opens no reader and carries no manual position. What
/// the two really share is the header's shape and the unnamed chip, and the chip
/// is shared as a type so the two cannot draw "no name" differently.
struct ScratchListSection: View {
    let group: ScratchModel.RowGroup
    let isCollapsed: Bool
    let onToggle: (String) -> Void
    @ObservedObject var model: ScratchModel
    /// Forwarded to every row, so a click in one hands the keyboard back to the
    /// feed — the rows handle their own taps, so the pane never sees them.
    let onInteract: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if !isCollapsed {
                rows
            }
        }
        // Breathing room beneath each group so the no-list notes and every named
        // list read as separated blocks, matching the index surfaces.
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 14)
            // Named lists show their name; the no-list group shows the dashed
            // placeholder chip in the name's slot, so it reads as "the group with
            // no name" without inventing a label that could leak into the list
            // pickers or the list-name CLI.
            if let name = group.listName {
                Text(name).font(.subheadline).bold().foregroundStyle(.secondary)
            } else {
                UnnamedGroupChip()
            }
            Text("\(group.entries.count)")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        // The pane's one inset, so the caret lands on the same vertical line as
        // the checkbox gutter below it. The index surfaces inset by their drag
        // grip's column for the same reason; the rule is shared, the literal is
        // not, because a note has no grip.
        .padding(.leading, ScratchMetrics.inset)
        .padding(.trailing, 8).padding(.vertical, 8)
        .contentShape(Rectangle())
        .pointerButton(onHoverChange: { _ in }, action: { onToggle(group.id) })
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
        }
    }

    @ViewBuilder
    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(group.entries) { row in
                ScratchRow(row: row, model: model, onInteract: onInteract)
                    // Explicit id so the pane's ScrollViewReader can scroll the
                    // keyboard-focused note into view.
                    .id(row.id)
                // A hairline under every note, the last one included: it closes
                // the group the way the header's rule opens it.
                Divider()
            }
        }
    }
}
