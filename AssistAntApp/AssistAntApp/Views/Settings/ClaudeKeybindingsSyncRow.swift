import SwiftUI
import Galactic

/// The half of the text-entry settings that is not automatic.
///
/// The keystrokes above this row reach the note and annotation composers
/// directly, so they are always current. The Claude session pane is different:
/// it answers to `~/.claude/keybindings.json`, a file outside this app that a
/// companion app also writes and that a person can edit by hand. When that file
/// disagrees with these settings, something has to say so and offer a
/// direction — which is what this row is.
///
/// Two buttons rather than one because the remedies are opposite and only the
/// person looking knows which they want. Nothing in the file records who wrote
/// it, so guessing a direction on their behalf would be guessing.
struct ClaudeKeybindingsSyncRow: View {
    @ObservedObject var settingsManager: SettingsManager

    /// Re-read whenever this appears and after either button, rather than
    /// watching the file. A watcher would only pay off while someone sits
    /// looking at this row, and the read is far colder than the one every
    /// automated submission already performs.
    @State private var state: ClaudeKeybindingsWriter.FileState?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Claude session pane")
                .font(.system(size: 11, weight: .semibold))
            if let state {
                Text(summary(for: state))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                buttons(for: state)
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: settingsManager.settings.textEntry) { _, _ in refresh() }
    }

    @ViewBuilder
    private func buttons(
        for state: ClaudeKeybindingsWriter.FileState
    ) -> some View {
        // Matching needs no button at all: there is no direction to choose and
        // an enabled control would invite a write that changes nothing.
        if state.relation != .matching {
            HStack(spacing: 8) {
                Spacer()
                if state.relation != .notWritten {
                    if let refusal = state.adoptRefusal {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .help(refusalHelp(refusal))
                        Button("Adopt from file") {}
                            .disabled(true)
                            .help(refusalHelp(refusal))
                    } else {
                        Button("Adopt from file") {
                            settingsManager.adoptClaudeKeybindings()
                            refresh()
                        }
                        .help(adoptHelp(for: state))
                        .pointingHandCursor()
                    }
                }
                Button("Write to file") {
                    settingsManager.syncClaudeKeybindings()
                    refresh()
                }
                .help(
                    "Write these keystrokes into Claude Code's keybindings "
                        + "file. Bindings for other actions are left alone; "
                        + "submit and newline keys the settings above do not "
                        + "name are removed."
                )
                .pointingHandCursor()
            }
        }
    }

    private func refresh() {
        state = ClaudeKeybindingsWriter.fileState(
            for: settingsManager.settings.textEntry)
    }

    /// Say what the difference is, not who caused it — the file carries no
    /// authorship, and a reader recognises their own change faster than any
    /// guess this row could make.
    private func summary(
        for state: ClaudeKeybindingsWriter.FileState
    ) -> String {
        switch state.relation {
        case .notWritten:
            return
                "These keystrokes are not in Claude Code's keybindings file "
                + "yet, so the session pane is still on its own defaults."
        case .matching:
            return "Claude Code's keybindings file matches these keystrokes."
        case .differs:
            // Each clause names what the session pane is actually doing.
            // Earlier drafts described every difference as something the file
            // "does not carry", which for a still-active default said the
            // opposite of the truth: the key works, and shouldn't.
            var parts: [String] = []
            if !state.activeDefaults.isEmpty {
                parts.append(
                    "\(list(state.activeDefaults)) still works there because "
                        + "Claude Code binds it by default and the keystrokes "
                        + "above do not list it"
                )
            }
            if !state.extra.isEmpty {
                parts.append("the file also binds \(list(state.extra))")
            }
            if !state.missing.isEmpty {
                parts.append("it does not carry \(list(state.missing))")
            }
            let detail =
                parts.isEmpty
                ? "the two disagree"
                : parts.joined(separator: ", and ")
            return "The session pane does not match these keystrokes: \(detail)."
        }
    }

    private func adoptHelp(
        for state: ClaudeKeybindingsWriter.FileState
    ) -> String {
        let adopted = state.adopted
        let submit = (adopted?.submit ?? []).map(\.displayLabel)
        let newline = (adopted?.newline ?? []).map(\.displayLabel)
        return
            "Replace the keystrokes above with the file's: "
            + "submit \(list(submit)), newline \(list(newline)). "
            + "The current ones are discarded."
    }

    private func refusalHelp(_ sequences: String) -> String {
        "The file binds \(sequences) to submit or newline. That is a key "
            + "sequence, which this card cannot show, so adopting would drop "
            + "it silently. Remove it from ~/.claude/keybindings.json to "
            + "adopt — writing from here will not clear it."
    }

    private func list(_ items: [String]) -> String {
        items.isEmpty ? "nothing" : items.joined(separator: ", ")
    }
}

extension View {
    /// Hand cursor while the pointer is over a clickable control.
    ///
    /// Deliberately not applied to the disabled Adopt button. The cursor is
    /// part of the affordance, so offering it on a control that will not
    /// respond promises something the click cannot deliver.
    func pointingHandCursor() -> some View {
        onHover { inside in
            if inside {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}
