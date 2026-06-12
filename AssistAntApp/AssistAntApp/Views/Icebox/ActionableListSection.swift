import SwiftUI

/// One actionable list group. The no-list group (listName == nil) renders its
/// rows flat at the top with no header; a named list gets a chevron header that
/// collapses/expands its rows. Forwards the shared selection + actions to each
/// row so the same list renders on any surface (Icebox today, Schedule next).
struct ActionableListSection: View {
    let group: ActionableGroup
    let isCollapsed: Bool
    let onToggle: (String) -> Void
    let selection: ActionableSelection
    let actions: ActionableActions
    let onOpen: (Item) -> Void

    /// Indent for items under a named list, so a row's checkbox column lines up
    /// under the list-name text in the header (the disclosure caret hangs in the
    /// left margin) and the rows read as a sub-list. Every row leads with the
    /// selection gutter (focus bar + checkbox), so this is the header name's
    /// offset (pad 12 + caret 14 + spacing 6 = 32) minus the checkbox's offset
    /// within a row (outer pad 8 + gutter lead 6 + bar 3 + spacing 8 = 25).
    private static let nestedIndent: CGFloat = 7

    var body: some View {
        VStack(spacing: 0) {
            if let name = group.listName {
                header(name)
                if !isCollapsed {
                    rows.padding(.leading, Self.nestedIndent)
                }
            } else {
                rows   // no-list: flat, no header, top-level
            }
        }
        // Breathing room beneath each group so the no-list items and every
        // named sub-list read as separated blocks.
        .padding(.bottom, 14)
    }

    private func header(_ name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 14)
            Text(name).font(.subheadline).bold().foregroundStyle(.secondary)
            Text("\(group.items.count)")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .pointerButton(onHoverChange: { _ in }, action: { onToggle(name) })
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
                    actions: actions
                )
                // Explicit id so the pane's ScrollViewReader can scroll the
                // keyboard-focused row into view.
                .id(item.id)
            }
        }
    }
}
