import AppKit
import Combine
import Galactic

/// Contract for any terminal surface hostable by `TerminalHostView`.
/// Abstracts the session pane (the embedded Claude process) and the shell
/// pane into one interface covering scrollback, drag-drop, focus, font
/// zoom, and exit handling.
///
/// Conformers:
/// - `SessionTerminalPane` — wraps `AgentSessionController`'s backend
/// - `ShellTerminalPane` — wraps a `TerminalBackend` directly, with no
///   Claude coupling
///
/// This is the libghostty swap seam at the chrome boundary. Backends (PTY +
/// rendering library) swap via `TerminalBackend`; chrome hosts (drag-drop,
/// scrollback, focus, keyboard) swap via this protocol.
///
/// Ported from Galaxy's protocol of the same name, minus the members with no
/// AssistAnt analog: `ledgerSessionId` and `paneKind` exist there only to
/// attribute timeline events, `onBell` feeds a bell subsystem AssistAnt does
/// not have, and `onScrollUp` / `hasScrollbackContent` / `redraw` serve
/// scroll-to-enter-scrollback, which is deliberately unsupported here.
protocol TerminalPane: AnyObject {
    /// The inner NSView that renders the terminal.
    var view: NSView { get }

    /// Capture the current scrollback buffer for the overlay. Returns an
    /// opaque `ScrollbackSnapshot` the chrome can render immediately and
    /// again on font changes to reflow the same captured state. Nil when
    /// unavailable — pane teardown in progress, no active buffer.
    func captureScrollbackSnapshot() -> ScrollbackSnapshot?

    /// Send typed text. When `asPaste` is true and the terminal has
    /// bracketed-paste mode enabled, the pane wraps the text in
    /// bracketed-paste sequences so the remote process can tell a paste from
    /// typed input; otherwise the text goes verbatim. Used by drag-drop
    /// (bracketed paste) and keystroke injection (plain).
    func send(text: String, asPaste: Bool)

    /// Make the inner terminal the first responder.
    func focus()

    /// Whether this pane should accept dropped files right now. Gates
    /// drag-drop registration in `TerminalHostView.refreshDragRegistration`.
    var isAcceptingInput: Bool { get }

    /// Called when the underlying process terminates with an exit code. The
    /// owning container uses this to tear the pane down.
    var onProcessExit: ((Int32) -> Void)? { get set }

    /// Target that receives "Send to Claude" pastes from this pane's
    /// scrollback. The session pane targets its own terminal; the shell pane
    /// targets the session's.
    ///
    /// Nil when sending is fundamentally impossible. Non-nil with a set
    /// `disabledReason` means the UI shows the button disabled with that
    /// tooltip.
    var sendToClaudeTarget: SendToClaudeTarget? { get }

    /// Current viewport top row inside the scrollback buffer. The chrome
    /// uses this as the initial scroll position when opening the overlay.
    var viewportRow: Int { get }

    /// Clear any active text selection on the underlying terminal. Called
    /// before opening the scrollback overlay.
    func clearSelection()

    /// Active font on the underlying terminal surface. The scrollback HTML
    /// renderer reads `fontName` and `pointSize` to match the live cells.
    var font: NSFont { get }

    /// Pixel height of one terminal cell. Drives CSS line-height in the
    /// overlay so frozen cells align with their live counterparts.
    var cellHeight: CGFloat { get }

    /// Snap the viewport to the bottom of the scrollback buffer and clear
    /// the `userScrolling` gate so subsequent output auto-follows.
    /// Unconditional — no threshold, no selection guard.
    func snapViewportToBottom()

    /// Current font size for this pane's terminal. Per-pane, so the session
    /// and shell panes can diverge independently.
    var fontSize: CGFloat { get }

    /// Emits whenever `fontSize` changes, so `TerminalHostView` can
    /// re-render an open scrollback overlay with updated metrics without
    /// caring which pane kind it hosts.
    var fontSizePublisher: AnyPublisher<CGFloat, Never> { get }

    /// Bump this pane's font size one step, up to the global ceiling.
    func increaseFontSize()

    /// Drop this pane's font size one step, down to the global floor.
    func decreaseFontSize()

    /// Reset this pane's font size to `AppSettings.defaultTerminalFontSize`.
    func resetFontSize()

    /// Whether the font size is below the ceiling and can take another
    /// increase step. Drives the View ▸ Bigger menu item's enabled state.
    var canIncreaseFontSize: Bool { get }

    /// Whether the font size is above the floor and can take another
    /// decrease step. Drives the View ▸ Smaller menu item's enabled state.
    var canDecreaseFontSize: Bool { get }

    /// Trim the terminal's scrollback and reflow the viewport.
    func trimBuffer()

    /// Reflow the viewport without trimming scrollback.
    func reflowBuffer()

    /// Re-assert live-bottom follow when the user intends to be following —
    /// a no-op in scrollback or when parked. Fired on focus-class events.
    func reassertFollowIfIntended()
}

/// Where a "Send to Claude" action routes its formatted message, and the
/// preflight check that gates the send.
///
/// Both panes produce one of these; the scrollback overlay consults
/// `disabledReason()` to decide whether the button is enabled, then calls
/// `sendText` followed by `sendCR`.
struct SendToClaudeTarget {
    /// Inject text into the target terminal.
    let sendText: (String) -> Void

    /// Send a single CR to submit. Called a beat after `sendText` so the TUI
    /// registers the paste as input before Enter arrives.
    let sendCR: () -> Void

    /// Preflight: nil enables the button, a string disables it and supplies
    /// the tooltip.
    let disabledReason: () -> String?
}
