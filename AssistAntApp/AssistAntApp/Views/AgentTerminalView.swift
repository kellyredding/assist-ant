import AppKit
import SwiftUI
import Galactic

/// SwiftUI wrapper that mounts the Galactic backend's NSView. A simplified
/// single-session port — multi-pane focus arbitration is dropped since
/// AssistAnt embeds exactly one session. The host owns the scrollback
/// overlay lifecycle, so it takes the whole backend (not just its view).
struct AgentTerminalView: NSViewRepresentable {
    let backend: TerminalBackend
    /// Whether the Agent tab is the active tab. The terminal only holds first
    /// responder while active — otherwise keys pressed on another tab (e.g.
    /// j/k list navigation) bubble into the live PTY.
    var isActive: Bool = true

    func makeNSView(context: Context) -> AgentTerminalHostView {
        AgentTerminalHostView(backend: backend)
    }

    func updateNSView(_ nsView: AgentTerminalHostView, context: Context) {
        // The backend's view is stable for the life of a session, so there is
        // nothing to reconcile on re-render. Re-assert focus only while the
        // Agent tab is active (in case the view was just (re)mounted after a
        // window reopen); when it isn't, give up first responder so other tabs'
        // keystrokes can't bleed into the PTY. Refresh drag registration so the
        // terminal is a drop target only while running (mirrors Galaxy).
        if isActive {
            nsView.requestFocus()
        } else {
            nsView.resignFocusIfHeld()
        }
        nsView.refreshDragRegistration()
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
            // Mount the drag-highlight overlay above the terminal surface
            // (hidden until a file drag enters) and register for file drops
            // now that we're in a window. Mirrors Galaxy's DragHighlightView
            // mount + dynamic drag registration.
            let highlight = DragHighlightView(frame: paddedBounds())
            highlight.autoresizingMask = []
            addSubview(highlight, positioned: .above, relativeTo: terminalView)
            dragHighlightView = highlight
            refreshDragRegistration()
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
        let inner = paddedBounds()
        terminalView.frame = inner
        dragHighlightView?.frame = inner
    }

    private func paddedBounds() -> NSRect {
        bounds.insetBy(dx: Self.padding, dy: Self.padding)
    }

    func requestFocus() {
        // Only the active Agent tab may take terminal focus. Without this guard
        // an early-lifecycle focus grab (viewDidMoveToWindow, scrollback dismiss)
        // could seize first responder while another tab is showing, so that
        // tab's unhandled keystrokes would bleed into the live PTY.
        guard MainTabNavigator.shared.selectedTab == .agent else { return }
        guard let window = window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            _ = window.makeFirstResponder(self.terminalView)
            // Friendly re-pin: when the agent terminal regains focus (Agent
            // tab activation, app refocus, scrollback dismiss) and the user
            // is following the live tail, snap back to the bottom. No-op when
            // parked in scrollback — see Galactic's reassertFollowIfIntended.
            self.backend.reassertFollowIfIntended()
        }
    }

    /// Give up first responder when the Agent tab goes inactive, but only when
    /// the terminal is the one holding it — so keystrokes on another tab (e.g.
    /// j/k list navigation) fall to the responder chain instead of bleeding into
    /// the live PTY. Leaves other responders (a focused field elsewhere) alone.
    func resignFocusIfHeld() {
        guard let window, window.firstResponder === terminalView else { return }
        window.makeFirstResponder(nil)
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
        // Mount the overlay above the drag-highlight view so, while
        // scrollback is open, the overlay's ScrollbackDropWebView intercepts
        // file drags over itself; the terminal host's drag handlers are then
        // the safety path for drags reaching the live-terminal region.
        // Mirrors Galaxy's `addSubview(overlay, positioned: .above,
        // relativeTo: dragHighlightView)`.
        addSubview(overlay, positioned: .above, relativeTo: dragHighlightView)
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

    // MARK: - File drag-and-drop (bracketed paste)

    /// Drop-zone highlight overlay, drawn above the terminal surface and
    /// toggled on while a file drag hovers. Mirrors Galaxy's
    /// `dragHighlightView`.
    private var dragHighlightView: DragHighlightView?

    /// Whether a file drag is currently hovering the terminal — drives the
    /// highlight overlay. Mirrors Galaxy's `isReceivingDrag`.
    private var isReceivingDrag = false {
        didSet { dragHighlightView?.isHighlighted = isReceivingDrag }
    }

    /// Drops are accepted only while the single embedded session is running
    /// — the collapse of Galaxy's `isActive && pane.isAcceptingInput`.
    private var canAcceptDrop: Bool {
        AgentSessionController.shared.state == .running
    }

    /// Register for file drops only while running; unregister otherwise so a
    /// stopped session is not a drop target. Mirrors Galaxy
    /// `updateDragRegistration` / `refreshDragRegistration`; called from
    /// `AgentTerminalView.updateNSView` so it tracks session state.
    func refreshDragRegistration() {
        if canAcceptDrop {
            registerForDraggedTypes([.fileURL])
        } else {
            unregisterDraggedTypes()
        }
    }

    override func draggingEntered(
        _ sender: NSDraggingInfo
    ) -> NSDragOperation {
        // Refuse drops while any modal is presenting over our window:
        // app-modal Settings (NSApp.runModal) or window-modal sheets (every
        // SheetAlert.confirm — discard-notes, etc.). Prevents the
        // stale-render bug where a drop accepts the paste bytes but the
        // terminal doesn't repaint until a later event. Don't gate on
        // isKeyWindow — for Finder drags the source app stays active, so
        // neither of our windows is key during the drag, which would reject
        // every legitimate drop.
        guard !ModalState.isPresenting(over: window) else {
            NSCursor.operationNotAllowed.set()
            return []
        }

        // A file drag dismisses scrollback; if notes are unsaved, confirm
        // first instead of auto-dismissing.
        if scrollbackOverlay != nil {
            if scrollbackOverlay?.scrollbackView.hasNotes == true {
                showDismissConfirmation()
                return []
            }
            dismissScrollback()
        }

        guard canAcceptDrop else {
            // "Not allowed" cursor for a stopped session.
            NSCursor.operationNotAllowed.set()
            return []
        }

        // Accept only file URLs.
        guard sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) else {
            return []
        }

        isReceivingDrag = true
        NSCursor.dragCopy.set()
        return .copy
    }

    override func draggingUpdated(
        _ sender: NSDraggingInfo
    ) -> NSDragOperation {
        guard !ModalState.isPresenting(over: window), canAcceptDrop else {
            NSCursor.operationNotAllowed.set()
            return []
        }
        NSCursor.dragCopy.set()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isReceivingDrag = false
        NSCursor.arrow.set()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isReceivingDrag = false
        NSCursor.arrow.set()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isReceivingDrag = false
        NSCursor.arrow.set()

        // Defense-in-depth: same modal + accept guards as draggingEntered.
        // AppKit may not route performDragOperation when entered returned []
        // — but if it does, refuse cleanly.
        guard !ModalState.isPresenting(over: window), canAcceptDrop else {
            return false
        }

        // Bring the app and window forward when a file is dropped.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else {
            return false
        }

        // Deduplicate by standardized path (some drag sources duplicate).
        var seenPaths = Set<String>()
        var uniqueURLs: [URL] = []
        for url in urls {
            let path = url.standardized.path
            if !seenPaths.contains(path) {
                seenPaths.insert(path)
                uniqueURLs.append(url)
            }
        }

        // Raw space-joined paths + trailing space — Galaxy's exact format,
        // "like Cmd+V so Claude Code shows the gray-box treatment".
        let pathsText =
            uniqueURLs.map { $0.path }.joined(separator: " ") + " "

        // Send-to-session seam: bracketed paste, NO submit — the user
        // reviews the paths and presses Return themselves. Mirrors Galaxy's
        // performDragOperation (paste, no CR).
        AgentSessionController.shared.send(text: pathsText, asPaste: true)
        requestFocus()
        return true
    }
}
