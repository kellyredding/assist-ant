import AppKit
import SwiftUI

/// The Tasks tab's content: a read-only table of tasks over a run log.
///
/// Tasks are *authored agentically* — created and edited by talking to the
/// embedded agent (the `assist-ant task` CLI), not through a UI form — so this
/// pane has no add/edit affordances. It exposes only zero-form row verbs: an
/// enabled toggle, delete (with confirm), and a run-now ▶ placeholder that is
/// inert until the runner lands in a later phase. The list is a snapshot:
/// re-fetched on activation and on the control-bar refresh, mirroring
/// `IceboxPaneView` / `TrashPaneView`.
struct TasksPaneView: View {
    @ObservedObject private var model = TasksModel.shared
    @ObservedObject private var navigator = MainTabNavigator.shared

    @State private var pendingDelete: AgentTask?

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            // Tasks size to their content (a short config list); the run log
            // below takes the remaining height and scrolls.
            tasksContent
            Divider()
            logSection
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
        .onAppear { if navigator.selectedTab == .tasks { model.activate() } }
        .onChange(of: navigator.selectedTab) { _, tab in
            if tab == .tasks { model.activate() }
        }
        .confirmationDialog(
            "Delete this task?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { task in
            Button("Delete “\(task.name)”", role: .destructive) {
                model.delete(task)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { task in
            Text("“\(task.name)” will be removed. Its run history stays in the log.")
        }
    }

    // MARK: - Control bar

    /// A label and a refresh glyph that re-fetches the snapshot — the same
    /// idiom as `IceboxControlBar`.
    private var controlBar: some View {
        HStack(spacing: 12) {
            Text("Tasks").font(.headline)
            Spacer()
            PointerIconButton(
                systemName: "arrow.clockwise",
                help: "Reload tasks", action: { model.refresh() }
            )
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
    }

    // MARK: - Tasks table

    @ViewBuilder
    private var tasksContent: some View {
        if model.isLoading && model.tasks.isEmpty {
            ProgressView().scaleEffect(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else if model.tasks.isEmpty {
            // Compact, top-aligned empty line so the section stays small; same
            // style as the other panes' empty states.
            Text("No tasks yet")
                .font(.callout).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            // A plain stack (no scroll) so the section sizes to its content.
            LazyVStack(spacing: 0) {
                ForEach(model.tasks, id: \.id) { task in
                    TaskRowView(
                        task: task,
                        onRunNow: { model.runNow(task) },
                        onToggle: { model.setEnabled(task, $0) },
                        onDelete: { pendingDelete = task }
                    )
                    Divider().opacity(0.4)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Run log

    private var logSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Run Log").font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !model.runs.isEmpty {
                    Text("\(model.runs.count)")
                        .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            Divider()
            logContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The log fills the remaining height and overflow-scrolls; its empty state
    /// is centered like the other panes (Icebox / Trash).
    @ViewBuilder
    private var logContent: some View {
        if model.runs.isEmpty {
            VStack {
                Spacer()
                Text("No runs yet").font(.callout).foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.runs, id: \.id) { run in
                        TaskRunRowView(run: run)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

// MARK: - Task row

/// One task row: a trigger badge, the name + prompt preview, the recurring
/// last-run stamp, and the zero-form verbs (run-now placeholder, enabled
/// toggle, delete). A disabled task dims its text. No tap-to-open — tasks have
/// no reader in this phase.
private struct TaskRowView: View {
    let task: AgentTask
    let onRunNow: () -> Void
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            TriggerBadge(text: TaskFormat.triggerSummary(task))
                .frame(width: 96, alignment: .leading)

            nameLine
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(task.enabled ? 1 : 0.5)

            if let last = TaskFormat.lastRunText(task) {
                Text(last)
                    .font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            // Run now: deliver the task's prompt to the agent and log the run.
            // Stays enabled while the agent is down — it logs a skipped run.
            PointerIconButton(systemName: "play.fill", help: "Run now", action: onRunNow)

            Toggle("", isOn: Binding(get: { task.enabled }, set: onToggle))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
                .help(task.enabled ? "Disable task" : "Enable task")

            PointerIconButton(systemName: "trash", help: "Delete task", action: onDelete)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
        )
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
    }

    /// Name (semibold) followed by a muted single-line prompt preview — the
    /// same Gmail-style one-liner as the actionable rows.
    private var nameLine: Text {
        let name = Text(task.name).fontWeight(.semibold).foregroundStyle(.primary)
        let prompt = task.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.isEmpty { return name }
        return name + Text("  \(prompt)").foregroundStyle(.secondary)
    }
}

/// A small capsule labeling a task's trigger (e.g. "every 15m", "daily 07:00",
/// "one-shot", "manual").
private struct TriggerBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.secondary.opacity(0.12))
            )
    }
}

// MARK: - Run-log row

/// One run-log entry: a status glyph, the (snapshot) task name, the trigger
/// that fired it, an optional detail, and the fired-at time.
private struct TaskRunRowView: View {
    let run: TaskRun

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: run.status == "sent" ? "paperplane.fill" : "minus.circle")
                .font(.system(size: 11))
                .foregroundStyle(run.status == "sent"
                    ? Color(nsColor: .secondaryLabelColor)
                    : Color(nsColor: .tertiaryLabelColor))
                .frame(width: 18)

            Text(run.taskName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let detail = run.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Text(run.trigger)
                .font(.caption2).foregroundStyle(.secondary)

            Text(TaskFormat.dateTime.string(from: run.firedAt))
                .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

// MARK: - Display formatting

/// Pure formatting for the read-only table — lives in the view layer (not on
/// the GRDB record, which stays smoke-clean Foundation + GRDB).
private enum TaskFormat {
    static func triggerSummary(_ task: AgentTask) -> String {
        switch task.triggerType {
        case "recurring":
            switch task.cadenceKind {
            case "interval":
                if let s = task.intervalSeconds { return "every \(intervalText(s))" }
                return "recurring"
            case "daily":
                if let t = task.dailyTime { return "daily \(t)" }
                return "daily"
            default:
                return "recurring"
            }
        case "one_shot":
            return "one-shot"
        case "manual":
            return "manual"
        default:
            return task.triggerType
        }
    }

    /// A compact interval, snapping to the largest whole unit (900 → "15m",
    /// 3600 → "1h", 86400 → "1d").
    static func intervalText(_ seconds: Int) -> String {
        if seconds % 86_400 == 0 { return "\(seconds / 86_400)d" }
        if seconds % 3_600 == 0 { return "\(seconds / 3_600)h" }
        if seconds % 60 == 0 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }

    /// Recurring rows show the last-run stamp; other triggers show nothing.
    static func lastRunText(_ task: AgentTask) -> String? {
        guard task.triggerType == "recurring" else { return nil }
        guard let at = task.lastRunAt else { return "never run" }
        return "ran \(dateTime.string(from: at))"
    }

    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMdHmm")
        return f
    }()
}
