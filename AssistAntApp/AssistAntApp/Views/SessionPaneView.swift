import Combine
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

    /// The moment the agent behind this surface stops running.
    ///
    /// Mapped to a plain "still running or not" before deduplicating, because
    /// the reasons it stopped are several and none of them change the answer.
    /// The current value replays as `.running` — this view only exists in that
    /// state — so the deduplicated stream starts closed and opens once.
    private var surfaceEndings: SurfaceEndings {
        controller.$state
            .map { state in
                if case .running = state { return false }
                return true
            }
            .removeDuplicates()
            .filter { $0 }
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    /// What can stop this agent being written to.
    private var sendBlockerChanges: SendBlockerChanges {
        controller.$state.map { _ in () }.eraseToAnyPublisher()
    }

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
                        // No timeline here, so there is nowhere to record
                        // into and nothing is recorded. The describing stays
                        // in shared code either way.
                        timelineRecorder: nil,
                        settings: SettingsManager.shared,
                        findActivations: MenuActions.findActivations,
                        scrollbackActivations:
                            MenuActions.scrollbackActivations,
                        // Nothing here reports a turn, so there is nothing to
                        // record when one is cut short.
                        turnInterrupt: nil,
                        paneRegistry: TerminalPanes.shared,
                        surfaceEndings: surfaceEndings,
                        sendBlockerChanges: sendBlockerChanges,
                        // One session here, so it is always the active one.
                        // Visibility is purely the tab.
                        isActiveSession: true,
                        isVisibleSurface:
                            navigator.selectedTab == .terminal,
                        // This app never hides a pane, so the tab ceasing to
                        // show is the whole question — there is no
                        // deselection to hang it off.
                        shouldResignFocus:
                            navigator.selectedTab != .terminal)
                        .equatable()
                } else {
                    // Defensive: running with no backend should not happen,
                    // but never show an empty pane.
                    AgentPlaceholderView(
                        caption: "Starting…", showSpinner: true)
                }
            case .starting:
                AgentPlaceholderView(
                    caption: "Starting…", showSpinner: true)
            case .stopped:
                StoppedAgentView { controller.startFresh() }
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
