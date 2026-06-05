import AppKit
import SwiftUI
import Galactic

/// SwiftUI wrapper that mounts the Galactic backend's NSView. A simplified
/// single-session port — multi-pane focus arbitration is dropped since
/// AssistAnt embeds exactly one session. The host owns the scrollback
/// overlay lifecycle, so it takes the whole backend (not just its view).
struct AgentTerminalView: NSViewRepresentable {
    let backend: TerminalBackend

    func makeNSView(context: Context) -> AgentTerminalHostView {
        AgentTerminalHostView(backend: backend)
    }

    func updateNSView(_ nsView: AgentTerminalHostView, context: Context) {
        // The backend's view is stable for the life of a session, so there
        // is nothing to reconcile on re-render. Re-assert focus in case the
        // view was just (re)mounted after a window reopen.
        nsView.requestFocus()
    }
}

/// Host NSView that holds the terminal surface, paints a small inset strip,
/// forwards focus to the terminal, and owns the scrollback overlay
/// lifecycle. Re-homes Galaxy's per-pane `TerminalHostView` scrollback
/// machinery onto AssistAnt's single embedded session.
final class AgentTerminalHostView: NSView {
    private let backend: TerminalBackend
    private let terminalView: NSView
    private static let padding: CGFloat = 4
    private var didSetUp = false

    /// The live scrollback overlay, or nil when not in scrollback mode.
    private var scrollbackOverlay: ScrollbackOverlayView?
    /// The frozen snapshot backing the open overlay; released on teardown.
    private var currentSnapshot: ScrollbackSnapshot?
    /// Observer token for the `.enterScrollback` menu notification.
    private var scrollbackObserver: Any?

    init(backend: TerminalBackend) {
        self.backend = backend
        self.terminalView = backend.view
        super.init(frame: .zero)
        wantsLayer = true
        observeScrollbackNotification()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let scrollbackObserver {
            NotificationCenter.default.removeObserver(scrollbackObserver)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if !didSetUp && window != nil {
            terminalView.frame = paddedBounds()
            terminalView.autoresizingMask = []
            addSubview(terminalView)
            didSetUp = true
            // Defer focus a runloop turn so the responder chain has settled
            // after the view is in a window.
            DispatchQueue.main.async { [weak self] in
                self?.requestFocus()
            }
        }
    }

    override func layout() {
        super.layout()
        terminalView.frame = paddedBounds()
    }

    private func paddedBounds() -> NSRect {
        bounds.insetBy(dx: Self.padding, dy: Self.padding)
    }

    func requestFocus() {
        guard let window = window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            _ = window.makeFirstResponder(self.terminalView)
        }
    }

    // Let the terminal own first responder; clicks focus it.
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        requestFocus()
        super.mouseDown(with: event)
    }

    // MARK: - Scrollback overlay

    /// Observe the Agent ▸ Scrollback (⌘S) menu action. Mirrors Galaxy's
    /// `TerminalView` notification observer, collapsed to the single host.
    private func observeScrollbackNotification() {
        scrollbackObserver = NotificationCenter.default.addObserver(
            forName: .enterScrollback, object: nil, queue: .main
        ) { [weak self] _ in
            self?.enterScrollback()
        }
    }

    /// Enter scrollback from the Agent ▸ Scrollback (⌘S) action. Mirrors
    /// Galaxy `enterScrollbackFromMenu`: only respond when the terminal
    /// surface holds focus and no overlay is already open; capture the
    /// live viewport position, clear selection, and open the overlay
    /// there. Like Galaxy's menu path, an empty buffer is allowed — the
    /// user can still annotate what is currently visible.
    private func enterScrollback() {
        guard window != nil, scrollbackOverlay == nil else { return }
        guard window?.firstResponder === terminalView else { return }
        let scrollPosition = backend.viewportRow
        backend.clearSelection()
        createScrollback(initialScrollLine: scrollPosition)
    }

    /// Build the scrollback overlay over an HTML rendering of the frozen
    /// terminal buffer. Mirrors Galaxy `createScrollback` collapsed to the
    /// single surface (no isActiveSurface, no find, no timeline).
    private func createScrollback(initialScrollLine: Int) {
        guard let snapshot = backend.captureScrollbackSnapshot() else {
            return
        }
        currentSnapshot = snapshot

        let font = backend.font
        let theme = TerminalColorTheme.theme(
            named: SettingsManager.shared.settings.terminalColorThemeName
        )
        let html = ScrollbackHTMLRenderer.render(
            snapshot: snapshot,
            theme: theme,
            fontFamily: font.fontName,
            fontSize: font.pointSize,
            cellHeight: backend.cellHeight
        )

        let webView = ScrollbackWebView(
            frame: terminalView.bounds,
            html: html,
            initialScrollLine: initialScrollLine,
            backgroundColor: theme.backgroundColorValue
        )
        webView.onDismiss = { [weak self] in
            self?.dismissScrollback()
        }
        // Esc/dismiss with unsaved notes: the in-page JS posts
        // confirmDismiss instead of dismiss. Show the discard
        // confirmation and tear down only on confirm. Mirrors Galaxy
        // `TerminalView` onConfirmDismiss.
        webView.onConfirmDismiss = { [weak self] in
            self?.showDismissConfirmation()
        }
        webView.onReady = { [weak self] in
            // Snap the live terminal to the bottom once the overlay is
            // visible — prevents a flash of the live view jumping — then
            // restore any note state.
            self?.backend.snapViewportToBottom()
            webView.restoreNoteState()
        }
        // "Send to Claude" routes back through the send-to-session seam:
        // tear down, bracketed-paste the composed message, then CR after
        // 0.3s so the TUI registers the paste before Enter. Mirrors
        // Galaxy `TerminalView.onSendToClaude` — same 0.3s delay.
        webView.onSendToClaude = { [weak self] message in
            guard let self else { return }
            self.dismissScrollback()
            AgentSessionController.shared.send(text: message, asPaste: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                AgentSessionController.shared.submit()
            }
        }
        // Note-form / edit / drag-replace discard confirmations route
        // through the same ported SheetAlert helper Galaxy uses, so the
        // in-overlay note CRUD has full discard-confirm parity.
        webView.onConfirmDiscardForm = { [weak self] in
            self?.showDiscardNoteFormConfirmation()
        }
        webView.onConfirmDiscardEdit = { [weak self] in
            self?.showDiscardNoteEditConfirmation()
        }
        webView.onConfirmDragReplace = { [weak self] startLine, endLine in
            self?.showDragReplaceNoteConfirmation(
                startLine: startLine, endLine: endLine
            )
        }

        let overlay = ScrollbackOverlayView(
            frame: paddedBounds(),
            scrollbackView: webView
        )
        overlay.autoresizingMask = []
        addSubview(overlay)
        scrollbackOverlay = overlay
        window?.makeFirstResponder(webView.webView)
    }

    /// Tear down the overlay and return focus to the live terminal.
    /// Mirrors Galaxy `performScrollbackTeardown` minus the timeline
    /// events. The unsaved-notes confirmation is KEPT — it gates this
    /// path via `showDismissConfirmation`.
    private func dismissScrollback() {
        guard let overlay = scrollbackOverlay else { return }
        // Hand first responder back to the live terminal only if the
        // web view currently owns it, so we don't steal focus.
        if window?.firstResponder === overlay.scrollbackView.webView {
            window?.makeFirstResponder(terminalView)
        }
        overlay.scrollbackView.teardown()
        overlay.removeFromSuperview()
        scrollbackOverlay = nil
        currentSnapshot = nil
        requestFocus()
    }

    /// Confirm before discarding unsaved scrollback notes — uses the
    /// ported `SheetAlert.confirm` helper exactly as Galaxy does
    /// (`showDismissConfirmation`): tear down on confirm, restore focus
    /// on cancel.
    private func showDismissConfirmation() {
        guard let overlay = scrollbackOverlay, let window else { return }
        let count = overlay.scrollbackView.notes.count
        SheetAlert.confirm(
            in: window,
            message: "Discard scrollback notes?",
            detail: "You have \(count) unsaved "
                + "note\(count == 1 ? "" : "s"). "
                + "They will be lost if you exit scrollback.",
            onConfirm: { [weak self] in self?.dismissScrollback() },
            onCancel: { [weak self] in self?.requestFocus() }
        )
    }

    /// Confirm discarding unsaved text in the new-note form. Mirrors
    /// Galaxy `showDiscardNoteFormConfirmation`.
    private func showDiscardNoteFormConfirmation() {
        guard let overlay = scrollbackOverlay, let window else { return }
        SheetAlert.confirm(
            in: window,
            message: "Discard note?",
            detail: "You have unsaved text in the note form. "
                + "It will be lost if you dismiss.",
            onConfirm: {
                overlay.scrollbackView.webView.evaluateJavaScript(
                    "ScrollbackManager.notes.forceDiscardForm()"
                )
            },
            onCancel: { [weak self] in self?.requestFocus() }
        )
    }

    /// Confirm discarding unsaved changes to a note being edited.
    /// Mirrors Galaxy `showDiscardNoteEditConfirmation`.
    private func showDiscardNoteEditConfirmation() {
        guard let overlay = scrollbackOverlay, let window else { return }
        SheetAlert.confirm(
            in: window,
            message: "Discard changes?",
            detail: "You have unsaved changes to this note. "
                + "They will be lost if you cancel editing.",
            onConfirm: {
                overlay.scrollbackView.webView.evaluateJavaScript(
                    "ScrollbackManager.notes.forceDiscardEdit()"
                )
            },
            onCancel: { [weak self] in self?.requestFocus() }
        )
    }

    /// Confirm replacing an unsaved note form with a fresh drag
    /// selection. Mirrors Galaxy `showDragReplaceNoteConfirmation`.
    private func showDragReplaceNoteConfirmation(
        startLine: Int, endLine: Int
    ) {
        guard let overlay = scrollbackOverlay, let window else { return }
        SheetAlert.confirm(
            in: window,
            message: "Discard note?",
            detail: "You have unsaved text in the note form. "
                + "It will be lost if you start a new note.",
            onConfirm: {
                overlay.scrollbackView.webView.evaluateJavaScript(
                    "ScrollbackManager.notes"
                    + ".showNoteForm(\(startLine), \(endLine))"
                )
            },
            onCancel: {
                overlay.scrollbackView.webView.evaluateJavaScript(
                    "ScrollbackManager.notes.focusForm()"
                )
            }
        )
    }
}
