import AppKit
import SwiftUI

/// Full-cover reader for a single task, shown over the Tasks pane — the same
/// chrome as `ActionableItemViewer`: a header, a meta bar carrying the row's
/// verbs, the full prompt, and this task's run history.
///
/// The prompt is inline-editable — the one approved relaxation of agentic
/// authoring; name, trigger, and cadence stay read-only here (changed by
/// talking to the manage-tasks skill). Closed by the header ✕ or Esc; while
/// editing, Esc cancels the edit instead.
struct TaskViewer: View {
    let task: AgentTask
    let timeFormat: TimeFormat
    /// This task's run history, filtered by the host pane.
    let runs: [TaskRun]
    let onClose: () -> Void
    let onRunNow: () -> Void
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void
    let onSavePrompt: (String) -> Void

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var editorFocused: Bool

    private var canSave: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            metaBar
            Divider()
            if isEditing { editSection } else { readSection }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.textBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(task.name).font(.headline)
                .lineLimit(1).truncationMode(.tail)
                .foregroundStyle(task.enabled ? .primary : .secondary)
            Spacer(minLength: 12)
            PointerIconButton(systemName: "xmark", help: "Close (Esc)", action: onClose)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color(.windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
        }
    }

    // MARK: - Meta bar (a superset of the row's verbs)

    private var metaBar: some View {
        HStack(spacing: 10) {
            TriggerBadge(text: TaskFormat.triggerSummary(task))
            if let when = TaskFormat.whenText(task, timeFormat) {
                Text(when).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            PointerIconButton(systemName: "play.fill", help: "Run now", action: onRunNow)
            Toggle("", isOn: Binding(get: { task.enabled }, set: onToggle))
                .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                .help(task.enabled ? "Disable task" : "Enable task")
            PointerIconButton(systemName: "trash", help: "Delete task", action: onDelete)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color(.textBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    // MARK: - Read mode (full prompt + run history)

    private var readSection: some View {
        VStack(spacing: 0) {
            // No "Prompt" label or edit glyph — ⌘↵ enters edit, matching the
            // actionable item reader.
            EventBodyTextView(markdown: task.prompt)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            Divider()
            sectionHeader("Run history") {
                if !runs.isEmpty {
                    Text("\(runs.count)").font(.caption).monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            history
        }
        // Esc closes the viewer; ⌘↵ enters edit.
        .overlay {
            keyShortcuts(
                onEscape: onClose,
                onCommandReturn: { draft = task.prompt; isEditing = true })
        }
    }

    @ViewBuilder
    private var history: some View {
        if runs.isEmpty {
            VStack {
                Spacer()
                Text("No runs yet").font(.callout).foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(runs, id: \.id) { run in
                        TaskRunRowView(run: run, timeFormat: timeFormat)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Edit mode (prompt text only)

    private var editSection: some View {
        VStack(spacing: 0) {
            TextEditor(text: $draft)
                .font(.body)
                .focused($editorFocused)
                .padding(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                )
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { DispatchQueue.main.async { editorFocused = true } }
            Divider()
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                CapsuleActionButton(title: "Cancel", action: { isEditing = false })
                CapsuleActionButton(title: "Save", action: save)
                    .opacity(canSave ? 1 : 0.4).disabled(!canSave)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color(.windowBackgroundColor))
        }
        // Esc cancels; ⌘↵ saves — matching the actionable item editor.
        .overlay { keyShortcuts(onEscape: { isEditing = false }, onCommandReturn: save) }
    }

    private func save() {
        guard canSave else { return }
        onSavePrompt(draft)
        isEditing = false
    }

    // MARK: - Helpers

    /// The viewer's key bindings as zero-size buttons — window-level key
    /// equivalents that fire without focus: Esc even over the read view, and
    /// ⌘↵ even while the text editor holds first responder (plain Return stays
    /// a newline). Mirrors the actionable reader's ⌘↵-toggles-edit / Esc-cancels.
    private func keyShortcuts(
        onEscape: @escaping () -> Void, onCommandReturn: @escaping () -> Void
    ) -> some View {
        ZStack {
            hiddenButton(onEscape).keyboardShortcut(.cancelAction)
            hiddenButton(onCommandReturn).keyboardShortcut(.return, modifiers: .command)
        }
    }

    private func hiddenButton(_ action: @escaping () -> Void) -> some View {
        Button("", action: action)
            .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    private func sectionHeader<Trailing: View>(
        _ title: String, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            trailing()
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}
