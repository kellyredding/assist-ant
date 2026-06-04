import AppKit
import SwiftUI
import Combine

/// Main AssistAnt window. Hosts ContentView. Restores its frame from
/// WindowStatePersistence on init and saves on every move/resize. Theme
/// follows SettingsManager live.
///
/// Window-state and theme observers both mirror Galaxy's MainWindowController
/// (~/projects/kellyredding/galaxy/GalaxyApp/GalaxyApp/MainWindowController.swift).
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private var themeObserver: AnyCancellable?

    init() {
        let hosting = NSHostingController(rootView: ContentView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Assist Ant"
        // The app name is redundant now that the titlebar carries the sidebar
        // toggle, so hide the text but keep the title bar chrome.
        window.titleVisibility = .hidden
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1680, height: 840))
        window.minSize = NSSize(width: 800, height: 500)
        window.center()
        window.isReleasedWhenClosed = false

        // Titlebar control to toggle the sidebar between its quarter and half
        // widths (snaps to the far end from the current width).
        let sidebarToggleVC = NSTitlebarAccessoryViewController()
        sidebarToggleVC.layoutAttribute = .leading
        let sidebarToggleHost = NSHostingView(rootView: SidebarToggleButton())
        sidebarToggleHost.frame = NSRect(x: 0, y: 0, width: 34, height: 22)
        sidebarToggleVC.view = sidebarToggleHost
        window.addTitlebarAccessoryViewController(sidebarToggleVC)

        super.init(window: window)
        window.delegate = self

        // Apply current theme immediately so the window opens in the right
        // appearance, then observe changes for the rest of its lifetime.
        applyTheme(SettingsManager.shared.settings.themePreference)
        themeObserver = SettingsManager.shared.$settings
            .map(\.themePreference)
            .removeDuplicates()
            .sink { [weak self] newTheme in
                self?.applyTheme(newTheme)
            }

        // Restore saved window frame + screen position. No-op on first
        // launch (no saved state); window stays centered at default size.
        restoreWindowState()
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// Update window.appearance from a ThemePreference. Passing nil makes
    /// the window inherit the system appearance — that is how "Match
    /// system" works.
    func applyTheme(_ theme: ThemePreference) {
        window?.appearance = nsAppearance(for: theme)
    }

    private func nsAppearance(for theme: ThemePreference) -> NSAppearance? {
        switch theme {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    // MARK: - Window state restoration

    /// Restore window frame and screen position from persisted state.
    /// Called once during init. On first launch (no saved state), the
    /// window stays centered at its default size.
    private func restoreWindowState() {
        guard let window = window,
              let saved = WindowStatePersistence.shared.load()
        else { return }

        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        // Restore the saved window frame first.
        let savedFrame = NSRect(
            x: saved.windowFrame.x,
            y: saved.windowFrame.y,
            width: saved.windowFrame.width,
            height: saved.windowFrame.height
        )
        window.setFrame(savedFrame, display: false)

        // Try to find the saved screen by localizedName.
        if let targetScreen = screens.first(where: {
            $0.localizedName == saved.screenIdentifier
        }) {
            // Screen found — move window there if it landed elsewhere.
            if window.screen != targetScreen {
                moveWindow(window, toScreen: targetScreen)
            }
        } else {
            // Screen disconnected — proportionally scale to a current
            // screen so the window doesn't end up offscreen.
            let currentScreen = window.screen ?? NSScreen.screens[0]
            scaleWindowProportionally(
                window,
                fromScreenFrame: saved.screenFrame,
                toScreen: currentScreen
            )
        }

        // Final safety: floor the restored size to the window's minimum
        // first — a saved frame from before the sidebar split can be smaller
        // than the current minSize, and a programmatic setFrame doesn't
        // reliably clamp to it — then constrain to the screen so the title
        // bar stays reachable.
        var floored = window.frame
        floored.size.width = max(floored.size.width, window.minSize.width)
        floored.size.height = max(floored.size.height, window.minSize.height)
        let constrained = window.constrainFrameRect(floored, to: window.screen)
        if constrained != window.frame {
            window.setFrame(constrained, display: true)
        }
    }

    /// Move window to a target screen, preserving its relative position
    /// within the screen.
    private func moveWindow(_ window: NSWindow, toScreen target: NSScreen) {
        guard let currentScreen = window.screen else { return }

        let currentFrame = currentScreen.visibleFrame
        let relX = (window.frame.origin.x - currentFrame.origin.x)
            / currentFrame.width
        let relY = (window.frame.origin.y - currentFrame.origin.y)
            / currentFrame.height

        let targetFrame = target.visibleFrame
        let newX = targetFrame.origin.x + (relX * targetFrame.width)
        let newY = targetFrame.origin.y + (relY * targetFrame.height)

        var newFrame = window.frame
        newFrame.origin = NSPoint(x: newX, y: newY)
        window.setFrame(newFrame, display: true)
    }

    /// Proportionally scale window position and size when the original
    /// screen is no longer available.
    private func scaleWindowProportionally(
        _ window: NSWindow,
        fromScreenFrame saved: PersistedScreenFrame,
        toScreen current: NSScreen
    ) {
        let currentFrame = current.visibleFrame

        let relX = (window.frame.origin.x - saved.x) / saved.width
        let relY = (window.frame.origin.y - saved.y) / saved.height
        let relW = window.frame.width / saved.width
        let relH = window.frame.height / saved.height

        var newW = relW * currentFrame.width
        var newH = relH * currentFrame.height
        let newX = currentFrame.origin.x + (relX * currentFrame.width)
        let newY = currentFrame.origin.y + (relY * currentFrame.height)

        newW = max(newW, window.minSize.width)
        newH = max(newH, window.minSize.height)

        let newFrame = NSRect(x: newX, y: newY, width: newW, height: newH)
        window.setFrame(newFrame, display: true)
    }

    // MARK: - NSWindowDelegate (save triggers)

    func windowDidMove(_ notification: Notification) {
        guard let window = window else { return }
        WindowStatePersistence.shared.saveWindowState(for: window)
    }

    /// windowDidResize fires for ALL resizes — both live (user drag) and
    /// programmatic (Hammerspoon, AppleScript, accessibility APIs). Skip
    /// during live resize to avoid per-frame writes; windowDidEndLiveResize
    /// captures the final size.
    func windowDidResize(_ notification: Notification) {
        guard let window = window, !window.inLiveResize else { return }
        WindowStatePersistence.shared.saveWindowState(for: window)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = window else { return }
        WindowStatePersistence.shared.saveWindowState(for: window)
    }
}
