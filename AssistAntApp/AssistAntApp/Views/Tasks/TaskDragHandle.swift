import SwiftUI

/// The leading drag grip on a task row — a thin wrapper over the shared
/// `DragGripView` (the same AppKit grip the actionable rows use: reliable
/// cursor + drag-end + floating chip), wired to `TaskDragSession` and a
/// task-shaped chip.
struct TaskDragHandle: View {
    let task: AgentTask
    let isRowHovering: Bool
    static let columnWidth: CGFloat = 22

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        DragGripView(
            dragID: task.id,
            isRowHovering: isRowHovering,
            onBegin: { screenPoint in
                TaskDragSession.shared.begin(.init(id: task.id, name: task.name))
                DragPreviewPanel.shared.show(
                    TaskDragChip(task: task, isDark: scheme == .dark),
                    isDark: scheme == .dark, at: screenPoint)
            },
            onMoved: { screenPoint in DragPreviewPanel.shared.move(to: screenPoint) },
            onEnd: { TaskDragSession.shared.end(); DragPreviewPanel.shared.hide() })
        .frame(width: Self.columnWidth, height: 20)
        .accessibilityLabel("Reorder")
    }
}

/// The floating chip shown under the cursor while dragging a task — the trigger
/// badge + the task name, mirroring the row. Concrete theme-matched background
/// so it reads in dark mode.
private struct TaskDragChip: View {
    let task: AgentTask
    let isDark: Bool
    var body: some View {
        HStack(spacing: 8) {
            TriggerBadge(text: TaskFormat.triggerSummary(task))
            Text(task.name)
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
