import SwiftUI

/// One actionable list group. Every group gets a chevron header that
/// collapses/expands its rows — a named list shows its name; the no-list group
/// (listName == nil) shows a dashed placeholder chip. Collapse is keyed by the
/// group's id. Forwards the shared selection + actions to each row so the same
/// list renders on any surface (Icebox, Schedule, Trash, Today).
struct ActionableListSection: View {
    let group: ActionableGroup
    let isCollapsed: Bool
    let onToggle: (String) -> Void
    /// The selectable surfaces pass their selection; the Today sidebar omits it
    /// (defaulting to the shared disabled selection) — its rows render no gutter.
    var selection: ActionableSelection = .disabled
    let actions: ActionableActions
    let onOpen: (Item) -> Void
    /// Forwarded to each row to pick its surface-specific dimming + status.
    var context: ActionableRow.Context = .icebox

    var body: some View {
        VStack(spacing: 0) {
            header
            if !isCollapsed {
                rows
            }
        }
        // Breathing room beneath each group so the no-list items and every
        // named sub-list read as separated blocks.
        .padding(.bottom, 14)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 14)
            // Named lists show their name; the no-list group shows a dashed
            // placeholder chip in the name's slot, so it reads as "the group
            // with no name" without inventing a label that could leak into the
            // list pickers or the list-name CLI.
            if let name = group.listName {
                Text(name).font(.subheadline).bold().foregroundStyle(.secondary)
            } else {
                UnnamedGroupChip()
            }
            Text("\(group.items.count)")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .contentShape(Rectangle())
        // Collapse is keyed by the group's id (== the name for a named list, a
        // reserved sentinel for the no-list group), so both collapse with one
        // mechanism and the sentinel never enters the real list-name space.
        .pointerButton(onHoverChange: { _ in }, action: { onToggle(group.id) })
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(group.items, id: \.id) { item in
                ActionableRow(
                    item: item,
                    onOpen: { onOpen(item) },
                    selection: selection,
                    actions: actions,
                    context: context
                )
                // Explicit id so the pane's ScrollViewReader can scroll the
                // keyboard-focused row into view.
                .id(item.id)
            }
        }
    }
}

/// The label for the no-list group's collapsible header: a dashed-outline
/// placeholder sitting where a named list shows its name. It reads as "the
/// group with no name" without inventing a fake list label — nothing here is a
/// real list name, so it never reaches the list pickers or the list-name CLI.
private struct UnnamedGroupChip: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .strokeBorder(
                Color.secondary.opacity(0.7),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(width: 44, height: 15)
            .accessibilityLabel("Items with no list")
    }
}
