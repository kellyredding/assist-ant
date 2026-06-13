import AppKit
import KeyboardShortcuts
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
    private var model: CaptureModel?
    private var pinnedTop: NSPoint?
    private var resizeObserver: Any?
    private var becomeKeyObserver: Any?

    /// Register the per-kind global capture shortcuts. Called once at launch.
    /// Each shortcut summons the popover preset to its kind. KeyboardShortcuts
    /// delivers these callbacks on the main thread.
    func installCaptureShortcuts() {
        for kind in CaptureKind.allCases {
            KeyboardShortcuts.onKeyUp(for: .capture(for: kind)) { [weak self] in
                self?.summon(kind: kind)
            }
        }
    }

    /// Summon the popover preset to `kind`. Closed → present at `kind`; open on
    /// a different kind → switch in place (no re-arm); open on the same kind →
    /// toggle closed.
    private func summon(kind: CaptureKind) {
        guard let panel, let model else { present(kind: kind); return }
        if model.kind == kind {
            dismiss()
        } else {
            model.kind = kind
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            focusField()
        }
    }

    private func present(kind: CaptureKind) {
        prevApp = NSWorkspace.shared.frontmostApplication

        let theme = SettingsManager.shared.settings.themePreference
        let model = CaptureModel(kind: kind)
        self.model = model
        let content = CaptureContentView(
            model: model,
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

        // Focus the capture field deterministically rather than via fixed
        // timers — the timers raced the window's key transition, so a repeat
        // summon would sometimes fire makeFirstResponder before the panel
        // became key, and becoming key then clobbered the responder (the
        // intermittent "didn't focus on relaunch" bug). Instead: make the
        // field the panel's initial first responder, and re-assert focus on
        // every become-key. Whenever the panel actually takes key, focus lands
        // in the field — no timing assumptions.
        panel.initialFirstResponder = captureTextView()
        becomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            self?.focusField()
        }

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // After a cross-screen activation the panel can land front-but-not-key;
        // re-key on the next tick so it takes key (firing didBecomeKey above).
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let panel, self?.panel === panel else { return }
            panel.makeKeyAndOrderFront(nil)
            self?.focusField()
        }
        // Auto-arm Wispr hands-free once the field is focused — but only for a
        // direct Ask summon, and only if the user left it enabled. Switching
        // kinds inside an open popover routes through summon(kind:), never
        // here, so it can't arm.
        if kind == .ask, SettingsManager.shared.settings.captureAutoArmWisprOnAsk {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard self?.panel != nil else { return }
                WisprArmer.arm()
            }
        }
    }

    /// Make the capture text field first responder — used for initial focus on
    /// summon, on every panel become-key, and to re-focus after clicking a kind
    /// glyph (which would otherwise leave focus on the button).
    func focusField() {
        guard let panel, let tv = captureTextView() else { return }
        panel.makeFirstResponder(tv)
    }

    /// Walk the panel's content tree for the capture text view.
    private func captureTextView() -> SendingTextView? {
        guard let content = panel?.contentView else { return nil }
        func find(_ view: NSView) -> SendingTextView? {
            if let tv = view as? SendingTextView { return tv }
            for sub in view.subviews { if let r = find(sub) { return r } }
            return nil
        }
        return find(content)
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
        if let becomeKeyObserver {
            NotificationCenter.default.removeObserver(becomeKeyObserver)
        }
        becomeKeyObserver = nil
        pinnedTop = nil
        panel?.orderOut(nil)
        panel = nil
        model = nil
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
