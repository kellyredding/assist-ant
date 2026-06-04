import AppKit
import SwiftUI
import Galactic

/// SwiftUI wrapper that mounts the Galactic backend's NSView. A simplified
/// single-session port — no drag-drop, scrollback overlay, or multi-pane
/// focus arbitration, since AssistAnt embeds exactly one session.
struct AgentTerminalView: NSViewRepresentable {
    let backend: TerminalBackend

    func makeNSView(context: Context) -> AgentTerminalHostView {
        AgentTerminalHostView(terminalView: backend.view)
    }

    func updateNSView(_ nsView: AgentTerminalHostView, context: Context) {
        // The backend's view is stable for the life of a session, so there
        // is nothing to reconcile on re-render. Re-assert focus in case the
        // view was just (re)mounted after a window reopen.
        nsView.requestFocus()
    }
}

/// Host NSView that holds the terminal surface, paints a small inset strip,
/// and forwards focus to the terminal.
final class AgentTerminalHostView: NSView {
    private let terminalView: NSView
    private static let padding: CGFloat = 4
    private var didSetUp = false

    init(terminalView: NSView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
}
