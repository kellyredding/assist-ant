import SwiftUI

/// One icebox group. The no-list group (listName == nil) renders its rows
/// flat at the top with no header; a named list gets a chevron header that
/// collapses/expands its rows.
struct IceboxGroupSection: View {
    let group: IceboxGroup
    let isCollapsed: Bool
    let onToggle: (String) -> Void
    let onOpen: (Item) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let name = group.listName {
                header(name)
                if !isCollapsed { rows }
            } else {
                rows   // no-list: flat, no header, always shown
            }
        }
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
        ForEach(group.items, id: \.id) { item in
            IceboxRow(item: item, onOpen: { onOpen(item) })
        }
    }
}
