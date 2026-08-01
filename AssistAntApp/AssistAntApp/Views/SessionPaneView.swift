import SwiftUI
import Galactic

/// The session pane — the right side of the main window. Renders the embedded
/// `assist-ant` Claude session, or one of three non-running states
/// (starting / stopped / failed) driven by AgentSessionController.state.
/// Fills the space the resizable sidebar leaves.
struct SessionPaneView: View {
    @ObservedObject private var controller = AgentSessionController.shared
    @ObservedObject private var navigator = MainTabNavigator.shared
    @StateObject private var paneHolder = SessionPaneAdapterHolder()

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)

            switch controller.state {
            case .running:
                if let backend = controller.backend {
                    // Only hold keyboard focus while the Terminal tab is active,
                    // so other tabs' keystrokes can't bleed into the PTY.
                    // `.equatable()` matches the shell pane, so this host
                    // skips updateNSView on renders where neither the pane
                    // nor its active state changed. Without it the session
                    // host re-ran on every render while the shell host was
                    // skipped, making focus theft one-directional.
                    FocusableTerminalView(
                        pane: paneHolder.pane(
                            for: controller, backend: backend),
                        // One session here, so it is always the active one.
                        // Visibility is purely the tab.
                        isActiveSession: true,
                        isVisibleSurface:
                            navigator.selectedTab == .terminal,
                        paneRegistry: TerminalPanes.shared)
                        .equatable()
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
                    controller.startFresh()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: controller.state) { _, state in
            // Drop the cached adapter once the session leaves running, so the
            // backend it holds — and the scrollback buffer inside it — is
            // freed at stop time rather than lingering until the next spawn.
            // The controller nils its own backend in teardown; without this
            // the adapter would be the last strong reference.
            if state != .running { paneHolder.release() }
        }
    }

    // MARK: - Stopped

    /// Stopped state: the calm placeholder plus a primary-colored Start
    /// button. Start always begins a fresh session — a new id rather than a
    /// resume of the stored one — so persona and CLAUDE.md edits are picked
    /// up on the next run.
    private var stoppedView: some View {
        VStack(spacing: 16) {
            placeholderGlyph

            Text("Agent stopped")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)

            Button("Start") {
                controller.startFresh()
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

/// Caches one `SessionTerminalPane` per `SessionPaneView` lifetime, returning
/// the same instance for the same underlying backend. A stop-then-start cycle
/// builds a fresh backend, and with it a fresh adapter.
///
/// The cache lives in a plain (non-`@Published`) property so writing to it
/// during body evaluation doesn't re-trigger a SwiftUI update. Ported from
/// Galaxy's `SessionPaneAdapterHolder`.
final class SessionPaneAdapterHolder: ObservableObject {
    private var cached: SessionTerminalPane?

    func pane(
        for controller: AgentSessionController,
        backend: TerminalBackend
    ) -> SessionTerminalPane {
        if let cached, cached.backend === backend {
            return cached
        }
        let fresh = SessionTerminalPane(
            controller: controller, backend: backend
        )
        cached = fresh
        return fresh
    }

    /// Drop the cached adapter so the backend it holds can be released.
    func release() {
        cached = nil
    }
}
