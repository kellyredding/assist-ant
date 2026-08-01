import SwiftUI

/// Stopped state for the session pane: the placeholder glyph, the label, and
/// a primary Start button.
///
/// Start always begins a fresh session — a new id rather than a resume of the
/// stored one — so persona and CLAUDE.md edits are picked up on the next run.
/// The caller supplies the action so this view knows nothing about the
/// controller behind it.
struct StoppedAgentView: View {
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            AgentPlaceholderGlyph()

            Text("Agent stopped")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)

            Button("Start", action: onStart)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}
