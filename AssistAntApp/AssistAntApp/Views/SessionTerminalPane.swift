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

    /// No ledger here, so nothing to attribute events to.
    ///
    /// Stated rather than left to a default: a recorder drops every event whose
    /// session id is nil, so if this app ever gains a timeline, the events would
    /// go missing silently and the omission would look like the answer.
    var ledgerSessionId: Int64? { nil }

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

    var acceptsFileDrops: Bool { controller.state == .running }

    var paneKind: TerminalPaneKind { .session }

    // MARK: - Wired but unused here

    /// Forwarded to the engine so adopting bells here is genuinely supplying a
    /// closure. Nothing assigns it today, so bells go nowhere — but the path
    /// exists, which storage alone did not: a stored property would have
    /// accepted a closure and then never called it, because nothing carried the
    /// engine's callback to it.
    var onBell: (() -> Void)? {
        get { backend.onBell }
        set { backend.onBell = newValue }
    }

    /// Forwarded for the same reason. Scroll-to-enter-scrollback is off here —
    /// nothing assigns this, so a scroll-up is never consumed and ordinary
    /// scrolling proceeds.
    var onScrollUp: ((NSEvent) -> Bool)? {
        get { backend.onScrollUp }
        set { backend.onScrollUp = newValue }
    }

    /// Answered honestly rather than stubbed false: the engine knows, and a
    /// truthful answer is what lets scroll-to-enter be switched on here
    /// without revisiting this file.
    var hasScrollbackContent: Bool { backend.hasScrollbackContent }


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
