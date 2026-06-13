import AppKit
import SwiftUI

/// Owns the Quick Capture popover. Registers the global hotkey, and on summon
/// **activates AssistAnt** (so the capture field is the system's focused element
/// — Phase 0 found Wispr only dictates into the active/focused app) and
/// **restores the previously-frontmost app on dismiss**. Independent of the main
/// window and the embedded agent.
final class CapturePanelController {
    static let shared = CapturePanelController()

    private var panel: NSPanel?
    private var prevApp: NSRunningApplication?
    private let hotKey = CaptureHotKey()

    /// Register the global hotkey. Called once at launch.
    func installHotKey() {
        hotKey.install { [weak self] in
            DispatchQueue.main.async { self?.toggle() }
        }
    }

    private func toggle() {
        if panel != nil { dismiss() } else { present() }
    }

    private func present() {
        // Remember who was focused so dismiss can restore them.
        prevApp = NSWorkspace.shared.frontmostApplication

        let hosting = NSHostingController(
            rootView: CaptureContentView(onClose: { [weak self] in self?.dismiss() }))
        let fitting = hosting.view.fittingSize
        let initial = (fitting.width > 20 && fitting.height > 20)
            ? fitting : NSSize(width: 520, height: 210)

        let panel = CapturePanel(
            contentRect: NSRect(origin: .zero, size: initial),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = hosting
        self.panel = panel

        // Activate AssistAnt so the field becomes the focused element Wispr
        // targets, then show the panel key + centered.
        // Position on the screen under the pointer first, then show + key, then
        // activate. Re-assert key on the next turn: after cross-screen
        // activation the panel can end up front-but-not-key (AssistAnt's main
        // window, on its own screen, grabs key instead), which would drop field
        // focus and confuse focus restoration on dismiss.
        centerOnActiveScreen(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let panel, self?.panel === panel else { return }
            panel.makeKeyAndOrderFront(nil)
            NSLog("CapturePanel: shown isKey=\(panel.isKeyWindow) "
                + "appActive=\(NSApp.isActive) screen=\(panel.screen?.localizedName ?? "?")")
        }

        // Auto-arm Wispr hands-free so the user can just start talking. Routed
        // through Wispr's URL scheme (CGEvent synthesis is filtered by
        // WindowServer on current macOS) — no Accessibility needed. Fire after a
        // beat so the field is focused first; Wispr types into the focused field.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard self?.panel != nil else { return }
            WisprArmer.arm()
        }
    }

    /// Center the panel on the screen the user is working on (the one under the
    /// pointer), not whichever screen AssistAnt's main window happens to live on.
    private func centerOnActiveScreen(_ panel: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { panel.center(); return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2))
    }

    func dismiss() {
        // Stop hands-free so the mic doesn't keep listening after we close.
        WisprArmer.stop()
        panel?.orderOut(nil)
        panel = nil
        // Hand focus back to whatever app the user was in.
        NSLog("CapturePanel: dismiss restoring \(prevApp?.localizedName ?? "?")")
        prevApp?.activate()
        prevApp = nil
    }
}

/// Panel that can take key focus (so its text field can receive typing + Wispr
/// dictation) even with a hidden title bar.
final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
