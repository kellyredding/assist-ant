import AppKit
import Combine
import SwiftUI
import Galactic

/// SwiftUI wrapper that mounts a terminal pane's NSView. Accepts any
/// `TerminalPane` conformer so the session pane and the shell pane share one
/// SwiftUI→AppKit bridge without branching. The host owns the scrollback
/// overlay lifecycle, so it takes the whole pane (not just its view).
struct FocusableTerminalView: NSViewRepresentable, Equatable {
    let pane: TerminalPane
    /// Whether the Terminal tab is the active tab. The terminal only holds
    /// first responder while active — otherwise keys pressed on another tab
    /// (e.g. j/k list navigation) bubble into the live PTY.
    var isActive: Bool = true

    func makeNSView(context: Context) -> TerminalHostView {
        TerminalHostView(pane: pane)
    }

    /// Pane identity plus active state is the whole of this view's input, so
    /// `.equatable()` at the call site lets SwiftUI skip `updateNSView` — and
    /// with it a focus re-assert and drag re-registration — on renders where
    /// neither changed.
    static func == (
        lhs: FocusableTerminalView, rhs: FocusableTerminalView
    ) -> Bool {
        lhs.pane === rhs.pane && lhs.isActive == rhs.isActive
    }

    func updateNSView(_ nsView: TerminalHostView, context: Context) {
        let wasActive = nsView.isActive
        let activationChanged = isActive != wasActive
        nsView.isActive = isActive

        // Setting isActive refreshes drag registration when the value flips,
        // so only refresh explicitly when it didn't — the case where the
        // pane's own accepting-input state may have changed instead.
        if !activationChanged {
            nsView.refreshDragRegistration()
        }

        if !isActive {
            // Give up first responder so another tab's keystrokes can't bleed
            // into the PTY.
            nsView.resignFocusIfHeld()
        }

        // Take focus only on the transition into active, never on every
        // re-render. An unconditional grab steals first responder from
        // whatever the user is actually typing in, and with two panes both
        // hosts would race — the loser overwriting the focus memory that
        // decides where focus belongs. The preference gate settles it.
        if isActive && !wasActive {
            nsView.requestFocusIfPreferred()
        }
    }
}

/// Host NSView that holds the terminal surface, paints a small inset strip,
/// forwards focus to the terminal, and owns the scrollback overlay
/// lifecycle. Mirrors Galaxy's per-pane host of the same name, collapsed onto
/// AssistAnt's single embedded session.
final class TerminalHostView: NSView {
    /// Readable from outside so the ⌘W interceptor can ask which kind of pane
    /// a host is showing while walking up from the first responder.
    let pane: TerminalPane
    private let terminalView: NSView
    private static let padding: CGFloat = 4
    private var didSetUp = false

    /// Alpha applied to the pane's view when focus sits outside it. Tuned so
    /// the unfocused pane reads as clearly inactive without making its text
    /// hard to scan at a glance.
    private static let unfocusedPaneAlpha: CGFloat = 0.70

    /// Whether the Terminal tab is showing. Mirrors the SwiftUI wrapper's
    /// value so `updateNSView` can tell an activation transition from an
    /// ordinary re-render.
    var isActive: Bool = true {
        didSet {
            guard isActive != oldValue else { return }
            refreshDragRegistration()
        }
    }

    /// KVO on `window.firstResponder`, driving the focus dim and the record
    /// of which pane the user was last in. Bound in `viewDidMoveToWindow` so
    /// it exists only while attached to a window, and torn down in `deinit`.
    private var firstResponderObservation: NSKeyValueObservation?

    /// Which pane this host is showing.
    private var paneKind: TerminalPaneKind {
        pane is ShellTerminalPane ? .shell : .session
    }

    /// Galactic-owned container that hosts the terminal full-bleed
    /// inside a `padding` inset. SwiftTerm clips its leftmost column
    /// whenever the terminal view's own frame origin is offset from
    /// (0,0) of its superview, so the inset lives on the container,
    /// never on the terminal itself.
    private var terminalContainer: GalacticTerminalContainerView?

    /// The live scrollback overlay, or nil when not in scrollback mode.
    private var scrollbackOverlay: ScrollbackOverlayView?
    /// The frozen snapshot backing the open overlay; released on teardown.
    private var currentSnapshot: ScrollbackSnapshot?
    /// Observer token for the `.enterScrollback` menu notification.
    private var scrollbackObserver: Any?

    /// Observer token for our window becoming key.
    private var didBecomeKeyObserver: Any?

    /// Local key monitor translating Ctrl+←/→ into line-navigation controls.
    private var keyEventMonitor: Any?

    /// Subscriptions that keep the Send to Claude button's enabled state in
    /// step with its blockers. Bound while a scrollback is open, cleared on
    /// teardown.
    private var sendButtonStateCancellables = Set<AnyCancellable>()

    init(pane: TerminalPane) {
        self.pane = pane
        self.terminalView = pane.view
        super.init(frame: .zero)
        wantsLayer = true
        observeScrollbackNotification()
        observeWindowBecameKey()
        setupKeyEventMonitor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let scrollbackObserver {
            NotificationCenter.default.removeObserver(scrollbackObserver)
        }
        if let didBecomeKeyObserver {
            NotificationCenter.default.removeObserver(didBecomeKeyObserver)
        }
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
        }
        firstResponderObservation?.invalidate()
        TerminalPanes.shared.unregisterFocusRestorer(ObjectIdentifier(self))
        TerminalPanes.shared.unregisterUnsavedWorkChecker(
            ObjectIdentifier(self)
        )
        // Going away with a scrollback still open would strand the flag, and
        // with it leave the shell's Send disabled for good.
        if paneKind == .session, scrollbackOverlay != nil {
            TerminalPanes.shared.setSessionPaneScrollbackActive(false)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Rebind on every window move so the observer never outlives an
        // attachment or leaks across a reattachment.
        startObservingFirstResponder()
        if !didSetUp && window != nil {
            // Host the terminal full-bleed inside the Galactic inset
            // container so SwiftTerm never sees an offset frame (which
            // clips its left column); the container carries the padding.
            let container = GalacticTerminalContainerView(
                terminalView: terminalView,
                inset: Self.padding
            )
            container.frame = bounds
            container.autoresizingMask = []
            addSubview(container)
            terminalContainer = container
            // Mount the drag-highlight overlay above the terminal surface
            // (hidden until a file drag enters) and register for file drops
            // now that we're in a window. Mirrors Galaxy's DragHighlightView
            // mount + dynamic drag registration.
            let highlight = DragHighlightView(frame: paddedBounds())
            highlight.autoresizingMask = []
            addSubview(highlight, positioned: .above, relativeTo: container)
            dragHighlightView = highlight
            refreshDragRegistration()
            // Let cross-pane callers put focus back into this pane. Routing
            // through requestFocus() rather than the backend is what lets an
            // open scrollback overlay keep focus instead of the live terminal
            // underneath it.
            TerminalPanes.shared.registerFocusRestorer(
                ObjectIdentifier(self), kind: paneKind
            ) { [weak self] in
                self?.requestFocus()
            }
            // Let close and quit ask this pane whether discarding its
            // scrollback would lose anything.
            TerminalPanes.shared.registerUnsavedWorkChecker(
                ObjectIdentifier(self), kind: paneKind
            ) { [weak self] completion in
                guard let self = self else {
                    completion(false)
                    return
                }
                self.checkScrollbackUnsavedWork(completion: completion)
            }
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
        // Container fills the host and lays the terminal out full-bleed
        // inside the inset; overlays align to that inset (= paddedBounds).
        terminalContainer?.frame = bounds
        dragHighlightView?.frame = inner
    }

    private func paddedBounds() -> NSRect {
        bounds.insetBy(dx: Self.padding, dy: Self.padding)
    }

    func requestFocus() {
        // Only the active Terminal tab may take terminal focus. Without this
        // guard an early-lifecycle focus grab (viewDidMoveToWindow, scrollback
        // dismiss) could seize first responder while another tab is showing, so
        // that tab's unhandled keystrokes would bleed into the live PTY.
        guard MainTabNavigator.shared.selectedTab == .terminal else { return }
        guard let window = window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // With a scrollback open, focus belongs to the overlay's web view
            // rather than the live terminal behind it — otherwise scrollback
            // is visible but keyboard-dead, and Esc has nowhere to go.
            let focusingLivePane = self.scrollbackOverlay == nil
            let target: NSResponder =
                self.scrollbackOverlay?.scrollbackView.webView
                ?? self.terminalView
            // Friendly re-pin: when the terminal regains focus (tab
            // activation, app refocus, scrollback dismiss) and the user is
            // following the live tail, snap back to the bottom. Skipped when
            // focusing an overlay — someone reading frozen history must not
            // be yanked to the end.
            let reassertFollow = {
                if focusingLivePane { self.pane.reassertFollowIfIntended() }
            }
            if window.makeFirstResponder(target) {
                reassertFollow()
                return
            }
            // Retry once next runloop: a responder elsewhere may not have
            // finished resigning yet (settings closing, app refocus). One
            // retry suffices — repeated failure means something else is wrong.
            DispatchQueue.main.async { [weak window] in
                guard let w = window else { return }
                if w.makeFirstResponder(target) { reassertFollow() }
            }
        }
    }

    /// Take focus only when this pane is the one the user was last typing in.
    /// Without the gate both hosts grab on every activation and whichever runs
    /// last wins, overwriting the very memory that was meant to decide it.
    func requestFocusIfPreferred() {
        guard paneKind == TerminalPanes.shared.lastFocusedPaneKind else {
            return
        }
        requestFocus()
    }

    /// Give up first responder when the Terminal tab goes inactive, but only
    /// when this pane is the one holding it — so keystrokes on another tab
    /// (e.g. j/k list navigation) fall to the responder chain instead of
    /// bleeding into the live PTY. Leaves other responders alone.
    ///
    /// Checks descendants, not just the terminal view, so an open scrollback
    /// overlay's web view resigns too. Doing this before the pane is hidden
    /// also sidesteps AppKit's own auto-resign path inside `setHidden:`, which
    /// does a large amount of synchronous work when the first responder is a
    /// descendant of the view being hidden.
    func resignFocusIfHeld() {
        guard let window else { return }
        let responder = window.firstResponder
        let holdsFocus =
            responder === terminalView
            || (responder as? NSView)?.isDescendant(of: self) == true
        guard holdsFocus else { return }
        window.makeFirstResponder(nil)
    }

    // MARK: - Unsaved scrollback work

    /// Ask this pane's open scrollback whether it holds work that closing
    /// would discard. No overlay means nothing to lose. The answer lives in
    /// the page's own note state, so it has to be fetched from JavaScript —
    /// which is why the whole checker chain is asynchronous.
    private func checkScrollbackUnsavedWork(
        completion: @escaping (Bool) -> Void
    ) {
        guard let overlay = scrollbackOverlay else {
            completion(false)
            return
        }
        overlay.scrollbackView.webView.evaluateJavaScript(
            "ScrollbackManager.notes.hasUnsavedWork()"
        ) { result, _ in
            let hasWork = result as? Bool ?? false
            DispatchQueue.main.async {
                completion(hasWork)
            }
        }
    }

    // MARK: - Focus state

    /// (Re)bind the first-responder observer. Idempotent — the prior
    /// observation is invalidated first, and leaving a window simply leaves it
    /// torn down until the view is attached again.
    private func startObservingFirstResponder() {
        firstResponderObservation?.invalidate()
        firstResponderObservation = nil
        guard let window = window else { return }
        firstResponderObservation = window.observe(
            \.firstResponder, options: [.initial, .new]
        ) { [weak self] _, _ in
            self?.refreshFocusState()
        }
    }

    /// Dim this pane when focus is elsewhere, and record it as the last
    /// focused pane when focus is here. "Here" means this host or anything
    /// inside it, which covers the terminal surface, an open scrollback
    /// overlay, and anything nested we haven't thought of.
    private func refreshFocusState() {
        let responder = window?.firstResponder
        var isFocusInPane = false
        if let responderView = responder as? NSView {
            isFocusInPane =
                responderView === self
                || responderView.isDescendant(of: self)
        }

        // Animate the dim so focus changes don't snap. 150ms matches the
        // cadence AppKit uses for a window's own active/inactive transition.
        let target: CGFloat = isFocusInPane ? 1.0 : Self.unfocusedPaneAlpha
        if pane.view.alphaValue != target {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                pane.view.animator().alphaValue = target
            }
        }

        // An open scrollback covers the view that just dimmed, so it carries
        // the same signal itself — otherwise two open scrollbacks look
        // identical and neither says which one is taking keys.
        scrollbackOverlay?.isPaneFocused = isFocusInPane

        // Record on entry only. Focus leaving for a field elsewhere keeps the
        // memory pointing at the pane the user was actually typing in, so
        // coming back lands them where they left off.
        if isFocusInPane {
            TerminalPanes.shared.lastFocusedPaneKind = paneKind
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

    /// Repaint and re-focus when our window becomes key again.
    ///
    /// The engine stops refreshing its display while the window is inactive,
    /// so coming back can show cells that are several updates stale. Only the
    /// pane the user was last in re-asserts focus — without that gate both
    /// hosts would race on every app switch and whichever ran last would take
    /// focus regardless of where the user actually was.
    private func observeWindowBecameKey() {
        didBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, self.isActive else { return }
            guard let window = notification.object as? NSWindow,
                  window === self.window else { return }
            self.pane.redraw()
            guard paneKind == TerminalPanes.shared.lastFocusedPaneKind else {
                return
            }
            if window.firstResponder !== self.terminalView {
                self.requestFocus()
            }
        }
    }

    /// Translate Ctrl+← / Ctrl+→ into start-of-line and end-of-line controls,
    /// matching Terminal.app. The shell's readline and Claude's input both
    /// understand these; the arrows alone they do not.
    ///
    /// Guarding on this pane's terminal holding first responder is what keeps
    /// each host's monitor to its own pane, and what makes it inert while a
    /// scrollback is open — the web view holds focus then, so the keys reach
    /// the page instead of the process.
    private func setupKeyEventMonitor() {
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard let self else { return event }
            guard self.window?.firstResponder === self.terminalView else {
                return event
            }
            // Control alone. Option or Command in the mix means the user is
            // asking for something else entirely.
            let controlOnly = event.modifierFlags
                .intersection([.control, .option, .command]) == .control
            guard controlOnly else { return event }

            switch event.keyCode {
            case 123:  // Left arrow → start of line, as Ctrl-A
                self.pane.send(text: "\u{01}", asPaste: false)
                return nil
            case 124:  // Right arrow → end of line, as Ctrl-E
                self.pane.send(text: "\u{05}", asPaste: false)
                return nil
            default:
                return event
            }
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
        let scrollPosition = pane.viewportRow
        pane.clearSelection()
        createScrollback(initialScrollLine: scrollPosition)
    }

    /// Build the scrollback overlay over an HTML rendering of the frozen
    /// terminal buffer. Mirrors Galaxy `createScrollback` collapsed to the
    /// single surface (no isActiveSurface, no find, no timeline).
    private func createScrollback(initialScrollLine: Int) {
        guard let snapshot = pane.captureScrollbackSnapshot() else {
            return
        }
        currentSnapshot = snapshot

        let font = pane.font
        let theme = TerminalColorTheme.theme(
            named: SettingsManager.shared.settings.terminalColorThemeName
        )
        let html = ScrollbackHTMLRenderer.render(
            snapshot: snapshot,
            theme: theme,
            fontFamily: font.fontName,
            fontSize: font.pointSize,
            cellHeight: pane.cellHeight
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
            self?.pane.snapViewportToBottom()
            webView.restoreNoteState()
            // Push the button's starting state now that the page exists;
            // the subscriptions keep it current from here.
            self?.refreshSendButtonState()
        }
        // "Send to Claude" routes back through the send-to-session seam:
        // tear down, bracketed-paste the composed message, then CR after
        // 0.3s so the TUI registers the paste before Enter. Mirrors
        // Galaxy `TerminalView.onSendToClaude` — same 0.3s delay.
        webView.onSendToClaude = { [weak self] message in
            guard let self else { return }
            // Through the owning pane's target: the agent pane sends into
            // itself, the shell sends into the agent. Re-checking the gate
            // here covers the gap between the button being drawn and the
            // click arriving.
            guard let target = self.pane.sendToClaudeTarget,
                  target.disabledReason() == nil else { return }
            self.dismissScrollback()
            target.sendText(message)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                target.sendCR()
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
        webView.onConfirmSendWithUnsavedComment = { [weak self] in
            self?.showSendWithUnsavedCommentConfirmation()
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

        // Tell the other pane its target just froze, and start tracking the
        // blockers that decide whether this pane's own Send stays live.
        if paneKind == .session {
            TerminalPanes.shared.setSessionPaneScrollbackActive(true)
        }
        subscribeToSendButtonStateChanges()
        // Seed the overlay's focus tint. The observer is already running, but
        // it only fires on responder changes and this overlay just appeared.
        refreshFocusState()
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
        sendButtonStateCancellables.removeAll()
        if paneKind == .session {
            TerminalPanes.shared.setSessionPaneScrollbackActive(false)
        }
        requestFocus()
    }

    /// Push the pane's current Send-to-Claude availability into the open
    /// overlay. A no-op when no overlay is up.
    ///
    /// The reason text is escaped before interpolation so wording that
    /// contains an apostrophe can never break the inline script.
    private func refreshSendButtonState() {
        guard let overlay = scrollbackOverlay else { return }
        let target = pane.sendToClaudeTarget
        let reason = target?.disabledReason()
        let enabled = (target != nil && reason == nil)
        let escaped = (reason ?? "")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        overlay.scrollbackView.webView.evaluateJavaScript(
            "ScrollbackManager.setSendButtonState(\(enabled), '\(escaped)')"
        )
    }

    /// Subscribe to whatever can block this pane's Send, so the button
    /// enables and disables while the overlay is open rather than being
    /// judged once when it opened.
    private func subscribeToSendButtonStateChanges() {
        sendButtonStateCancellables.removeAll()

        // Both panes ultimately write into the agent's PTY, so both care
        // whether it is running.
        AgentSessionController.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshSendButtonState() }
            .store(in: &sendButtonStateCancellables)

        // Only the shell is additionally blocked by the agent pane's own
        // scrollback being frozen open.
        if pane is ShellTerminalPane {
            TerminalPanes.shared.$sessionPaneScrollbackActive
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshSendButtonState() }
                .store(in: &sendButtonStateCancellables)
        }
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
                + "It will be lost if you select different "
                + "lines.",
            onConfirm: {
                overlay.scrollbackView.webView.evaluateJavaScript(
                    "ScrollbackManager.notes"
                    + ".showSelectionToolbar("
                    + "\(startLine), \(endLine))"
                )
            },
            onCancel: {
                overlay.scrollbackView.webView.evaluateJavaScript(
                    "ScrollbackManager.notes.focusForm()"
                )
            }
        )
    }

    /// Confirm sending when an open note form or in-progress edit still
    /// holds comment text that Send would drop — only committed notes
    /// ship. On confirm, force the send past the JS guard; the open
    /// comment is discarded as teardown destroys the web view. Mirrors
    /// Galaxy `showSendWithUnsavedCommentConfirmation`.
    private func showSendWithUnsavedCommentConfirmation() {
        guard let overlay = scrollbackOverlay, let window else { return }
        SheetAlert.confirm(
            in: window,
            message: "Send without unsaved comment?",
            detail: "You have unsaved text in a comment that "
                + "won't be included. It will be lost if you send.",
            confirm: "Send",
            onConfirm: {
                overlay.scrollbackView.webView.evaluateJavaScript(
                    "ScrollbackManager.notes.sendToClaude(true)"
                )
            },
            onCancel: { [weak self] in self?.requestFocus() }
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

    /// Drops are accepted only while the hosted pane is accepting input —
    /// for the session pane, while the embedded session is running.
    private var canAcceptDrop: Bool {
        pane.isAcceptingInput
    }

    /// Register for file drops only while running; unregister otherwise so a
    /// stopped session is not a drop target. Mirrors Galaxy
    /// `updateDragRegistration` / `refreshDragRegistration`; called from
    /// `FocusableTerminalView.updateNSView` so it tracks session state.
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
        // performDragOperation (paste, no CR). Guarded by canAcceptDrop
        // above, which is what gates a send at a non-running session.
        pane.send(text: pathsText, asPaste: true)
        requestFocus()
        return true
    }
}
