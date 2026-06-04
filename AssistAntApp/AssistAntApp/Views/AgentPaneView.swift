import SwiftUI

/// The agent pane — the right side of the main window. Renders the embedded
/// `assist-ant` Claude session, or one of three non-running states
/// (starting / stopped / failed) driven by AgentSessionController.state.
/// Fills the space the resizable sidebar leaves.
struct AgentPaneView: View {
    @ObservedObject private var controller = AgentSessionController.shared

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)

            switch controller.state {
            case .running:
                if let backend = controller.backend {
                    AgentTerminalView(backend: backend)
                } else {
                    // Defensive: running with no backend should not happen,
                    // but never show an empty pane.
                    placeholder(caption: "Starting…", showSpinner: true)
                }
            case .starting:
                placeholder(caption: "Starting…", showSpinner: true)
            case .stopped:
                stoppedView
            case .failed(let reason):
                AgentFailureView(reason: reason) {
                    controller.restart()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Stopped

    /// Stopped state: the calm placeholder plus a primary-colored
    /// Start/Restart button. The label is "Restart" once a session id has
    /// ever been created (the common case), "Start" only before the first
    /// session exists.
    private var stoppedView: some View {
        VStack(spacing: 16) {
            placeholderGlyph

            Text("Agent stopped")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)

            Button(controller.sessionId == nil ? "Start" : "Restart") {
                controller.restart()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Placeholder building blocks

    private var placeholderGlyph: some View {
        Image(systemName: "terminal")
            .font(.system(size: 44, weight: .light))
            .foregroundStyle(.tertiary)
    }

    private func placeholder(
        caption: String, showSpinner: Bool
    ) -> some View {
        VStack(spacing: 12) {
            placeholderGlyph
            if showSpinner {
                ProgressView()
                    .controlSize(.small)
            }
            Text(caption)
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
    }
}
