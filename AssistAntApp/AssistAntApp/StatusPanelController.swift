import AppKit
import KeyboardShortcuts
import SwiftUI

/// Owns the Status popover — the main window's status column (clock, timezone,
/// mute state, and keyboard-navigable standing-desk controls) floated over any
/// app. Registers the global hotkey, activates AssistAnt on summon so its
/// window takes key (letting the desk controls' focus ring engage), and restores
/// the previously-frontmost app on dismiss. A borderless, themed, floating panel
/// that grows with its content. Independent of the main window and of the
/// capture popover.
///
/// Trimmed sibling of `CapturePanelController`: no text field, no Wispr, no
/// send — the popover only reads live state and drives `DeskService` actions,
/// then dismisses.
final class StatusPanelController {
    static let shared = StatusPanelController()

    private var panel: NSPanel?
    private var prevApp: NSRunningApplication?
    private var pinnedTop: NSPoint?
    private var resizeObserver: Any?
    private var moveObserver: Any?

    /// Top-center default: the panel's top edge sits this fraction of the visible
    /// screen height below the top — upper-area, not glued to the menu bar.
    private static let topMarginFraction: CGFloat = 0.15

    private init() {}

    /// Register the global status shortcut. Called once at launch. The shortcut
    /// toggles the popover; KeyboardShortcuts delivers the callback on the main
    /// thread.
    func installStatusShortcut() {
        KeyboardShortcuts.onKeyUp(for: .statusPopover) { [weak self] in
            self?.toggle()
        }
    }

    /// Open when closed; close when already open (mirrors the capture popover's
    /// same-shortcut toggle).
    private func toggle() {
        if panel != nil { dismiss() } else { present() }
    }

    private func present() {
        prevApp = NSWorkspace.shared.frontmostApplication

        let theme = SettingsManager.shared.settings.themePreference
        let content = StatusPopoverContent(
            colorScheme: Self.colorScheme(for: theme),
            onClose: { [weak self] in self?.dismiss() })
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = [.preferredContentSize] // window tracks content size

        let fitting = hosting.view.fittingSize
        let initial = (fitting.width > 20 && fitting.height > 20)
            ? fitting : NSSize(width: 420, height: 240)

        // Borderless: no titlebar gap, and we own the (themed, rounded)
        // background. canBecomeKey is overridden so its focus ring can take key.
        let panel = StatusPanel(
            contentRect: NSRect(origin: .zero, size: initial),
            styleMask: [.borderless],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true  // borderless: drag by the background
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = Self.nsAppearance(for: theme)
        panel.contentViewController = hosting
        self.panel = panel

        positionTopCenter(panel)

        // Pin the top-CENTER point so the panel stays horizontally centered and
        // grows downward from that top as content height changes (e.g. a phase
        // change swaps in a shorter/taller button row while it's open).
        pinnedTop = NSPoint(x: panel.frame.midX, y: panel.frame.maxY)
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self, weak panel] _ in
            guard let self, let panel, let top = self.pinnedTop else { return }
            let origin = NSPoint(
                x: top.x - panel.frame.width / 2, y: top.y - panel.frame.height)
            if abs(panel.frame.minX - origin.x) > 0.5
                || abs(panel.frame.minY - origin.y) > 0.5 {
                panel.setFrameOrigin(origin)
            }
        }

        // Keep the grow-downward anchor in sync with user drags (the resize
        // observer's own setFrameOrigin preserves the top, so its didMove is a
        // no-op — no feedback loop).
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self, weak panel] _ in
            guard let self, let panel else { return }
            self.pinnedTop = NSPoint(x: panel.frame.midX, y: panel.frame.maxY)
        }

        // Summoning from another app is a cross-app activation that lands
        // asynchronously; drive it to completion so the panel becomes key and
        // the SwiftUI focus ring (set on appear) engages.
        activate(panel, attempt: 0)
    }

    /// Place the panel horizontally centered and near the top of the active
    /// screen (the one under the pointer), top-anchored so the deterministic top
    /// doesn't shift with the panel's variable content height.
    private func positionTopCenter(_ panel: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { panel.center(); return }
        let size = panel.frame.size
        let originY = visible.maxY - visible.height * Self.topMarginFraction - size.height
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: originY))
    }

    /// Force the panel to key, retrying briefly to win the cross-app activation
    /// race a global-hotkey summon creates. Self-terminating: stops once the
    /// panel is key, when it's gone (dismissed mid-retry), or after ~0.5s.
    private func activate(_ panel: NSPanel, attempt: Int) {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        guard !panel.isKeyWindow, attempt < 12 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }
            self.activate(panel, attempt: attempt + 1)
        }
    }

    /// Dismiss and hand focus back to whatever app the user summoned from —
    /// unless that was us (a quick close→reopen can capture AssistAnt as
    /// prevApp), which would pointlessly steal activation back.
    func dismiss() {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
        resizeObserver = nil
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
        moveObserver = nil
        pinnedTop = nil
        panel?.orderOut(nil)
        panel = nil

        if let prevApp, prevApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            prevApp.activate()
        }
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

/// Panel that can take key focus so the desk controls' focus ring engages and
/// arrow / space / return reach the SwiftUI content, even though it's borderless.
final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
