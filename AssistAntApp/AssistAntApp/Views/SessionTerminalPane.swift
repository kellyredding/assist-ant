import AppKit
import Combine
import Galactic

/// `TerminalPane` conformer wrapping `AgentSessionController`'s backend —
/// the session pane, which hosts the embedded Claude process.
///
/// Thin adapter, zero behavior change. Everything Claude-specific (spawn,
/// resume reconciliation, the prompt queue, the settings subscription) stays
/// on `AgentSessionController`; this type only exposes the backend through
/// `TerminalPane` so `TerminalHostView` can host any pane kind generically.
///
/// Mirrors Galaxy's `SessionTerminalPane`, which adapts a `Session` instead.
/// AssistAnt embeds exactly one session owned by a singleton controller, so
/// Galaxy's `weak var session` and its optional-chained fallbacks collapse to
/// a direct reference.
final class SessionTerminalPane: TerminalPane {
    let controller: AgentSessionController
    let backend: TerminalBackend

    var view: NSView { backend.view }

    /// The session pane ignores this — the controller's own
    /// `onProcessTerminated` wiring is the source of truth for session exit.
    var onProcessExit: ((Int32) -> Void)?

    init(controller: AgentSessionController, backend: TerminalBackend) {
        self.controller = controller
        self.backend = backend
    }

    // MARK: - Terminal surface

    func captureScrollbackSnapshot() -> ScrollbackSnapshot? {
        backend.captureScrollbackSnapshot()
    }

    func send(text: String, asPaste: Bool) {
        backend.send(text: text, asPaste: asPaste)
    }

    func focus() { backend.focus() }

    var viewportRow: Int { backend.viewportRow }

    func clearSelection() { backend.clearSelection() }

    var font: NSFont { backend.font }

    var cellHeight: CGFloat { backend.cellHeight }

    func snapViewportToBottom() { backend.snapViewportToBottom() }

    func redraw() { backend.redraw() }

    func trimBuffer() { backend.trimBuffer() }

    func reflowBuffer() { backend.reflowBuffer() }

    func reassertFollowIfIntended() { backend.reassertFollowIfIntended() }

    var isAcceptingInput: Bool { controller.state == .running }

    // MARK: - Font zoom

    /// Session-pane font size lives on the controller so it survives pane
    /// teardown, and is published so an open scrollback overlay re-renders.
    var fontSize: CGFloat { controller.terminalFontSize }

    var fontSizePublisher: AnyPublisher<CGFloat, Never> {
        controller.$terminalFontSize.eraseToAnyPublisher()
    }

    func increaseFontSize() { controller.increaseFontSize() }

    func decreaseFontSize() { controller.decreaseFontSize() }

    func resetFontSize() { controller.resetFontSize() }

    var canIncreaseFontSize: Bool { controller.canIncreaseFontSize }

    var canDecreaseFontSize: Bool { controller.canDecreaseFontSize }

    // MARK: - Send to Claude

    /// The session pane routes scrollback sends back into its own terminal.
    ///
    /// Goes through the controller's prompt queue rather than the backend: the
    /// queue waits for the child to be reading before it writes, paces the
    /// submit behind the paste, and serializes against anything a scheduled
    /// task is already delivering. Galaxy sends its composed message
    /// unbracketed; AssistAnt has always pasted it, and the queue pastes too,
    /// so what the TUI sees is unchanged.
    var sendToClaudeTarget: SendToClaudeTarget? {
        guard controller.state == .running else {
            return SendToClaudeTarget(
                send: { _ in },
                disabledReason: { "Start the agent first" }
            )
        }
        let controller = self.controller
        return SendToClaudeTarget(
            send: { controller.enqueuePrompt($0) },
            disabledReason: { nil }
        )
    }
}
