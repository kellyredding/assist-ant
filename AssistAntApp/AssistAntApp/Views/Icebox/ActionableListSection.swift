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

    /// Indent for items under a named list, so a row's checkbox column lines up
    /// under the list-name text in the header (the disclosure caret hangs in the
    /// left margin) and the rows read as a sub-list. Every row leads with the
    /// selection gutter (focus bar + checkbox), so this is the header name's
    /// offset (pad 12 + caret 14 + spacing 6 = 32) minus the checkbox's offset
    /// within a row (outer pad 8 + gutter lead 6 + bar 3 + spacing 8 = 25).
    private static let nestedIndent: CGFloat = 7

    var body: some View {
        VStack(spacing: 0) {
            header
            if !isCollapsed {
                rows.padding(.leading, Self.nestedIndent)
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
        .padding(.horizontal, 12).padding(.vertical, 8)
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
