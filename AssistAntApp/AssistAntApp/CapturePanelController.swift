import AppKit
import SwiftUI

/// Owns the Quick Capture popover. Registers the global hotkey, and on summon
/// **activates AssistAnt** (so the capture field is the system's focused element
/// — Phase 0 found Wispr only dictates into the active/focused app) and
/// **restores the previously-frontmost app on dismiss**. A borderless, themed,
/// floating panel that grows with its content. Independent of the main window.
final class CapturePanelController {
    static let shared = CapturePanelController()

    private var panel: NSPanel?
    private var prevApp: NSRunningApplication?
    private let hotKey = CaptureHotKey()
    private var pinnedTop: NSPoint?
    private var resizeObserver: Any?

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
        prevApp = NSWorkspace.shared.frontmostApplication

        let theme = SettingsManager.shared.settings.themePreference
        let content = CaptureContentView(
            colorScheme: Self.colorScheme(for: theme),
            onKindSelected: { [weak self] in self?.focusField() },
            onClose: { [weak self] in self?.dismiss() })
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = [.preferredContentSize] // window tracks content size

        let fitting = hosting.view.fittingSize
        let initial = (fitting.width > 20 && fitting.height > 20)
            ? fitting : NSSize(width: 520, height: 200)

        // Borderless: no titlebar gap, and we own the (themed, rounded)
        // background. canBecomeKey is overridden so it still takes text input.
        let panel = CapturePanel(
            contentRect: NSRect(origin: .zero, size: initial),
            styleMask: [.borderless],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = Self.nsAppearance(for: theme)
        panel.contentViewController = hosting
        self.panel = panel

        centerOnActiveScreen(panel)

        // Pin the top edge so the window grows downward as the field grows,
        // instead of drifting up from a fixed bottom-left origin.
        pinnedTop = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self, weak panel] _ in
            guard let self, let panel, let top = self.pinnedTop else { return }
            let origin = NSPoint(x: top.x, y: top.y - panel.frame.height)
            if abs(panel.frame.minX - origin.x) > 0.5
                || abs(panel.frame.minY - origin.y) > 0.5 {
                panel.setFrameOrigin(origin)
            }
        }

        // Show + key, then activate, then re-assert key + focus the field
        // (after cross-screen activation the panel can end up front-but-not-key).
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let panel, self?.panel === panel else { return }
            panel.makeKeyAndOrderFront(nil)
            self?.focusField()
        }
        // Belt-and-suspenders: re-focus once the SwiftUI tree has built.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.focusField()
        }
        // Auto-arm Wispr hands-free once the field is focused.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard self?.panel != nil else { return }
            WisprArmer.arm()
        }
    }

    /// Make the capture text field first responder — used for initial focus on
    /// summon and to re-focus after clicking a kind glyph (which would
    /// otherwise leave focus on the button).
    func focusField() {
        guard let panel, let content = panel.contentView else { return }
        func find(_ view: NSView) -> SendingTextView? {
            if let tv = view as? SendingTextView { return tv }
            for sub in view.subviews { if let r = find(sub) { return r } }
            return nil
        }
        if let tv = find(content) { panel.makeFirstResponder(tv) }
    }

    private func centerOnActiveScreen(_ panel: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { panel.center(); return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2))
    }

    func dismiss() {
        // Stop hands-free so the mic doesn't keep listening after we close.
        WisprArmer.stop()
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
        resizeObserver = nil
        pinnedTop = nil
        panel?.orderOut(nil)
        panel = nil
        // Hand focus back to whatever app the user was in.
        prevApp?.activate()
        prevApp = nil
    }

    private static func nsAppearance(for theme: ThemePreference) -> NSAppearance? {
        switch theme {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    private static func colorScheme(for theme: ThemePreference) -> ColorScheme? {
        switch theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Panel that can take key focus (so its text field can receive typing + Wispr
/// dictation) even though it's borderless.
final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
