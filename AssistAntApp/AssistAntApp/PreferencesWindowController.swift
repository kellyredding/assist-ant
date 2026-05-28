import AppKit
import SwiftUI
import Combine

/// NSWindowController that hosts SettingsView as an app-modal window.
/// Uses NSApp.runModal(for:) to capture all key events, preventing
/// accidental keyboard shortcuts (like ⌘W) from leaking through to the
/// main window underneath.
///
/// Mirrors Galaxy's PreferencesWindowController
/// (~/projects/kellyredding/galaxy/GalaxyApp/GalaxyApp/PreferencesWindowController.swift).
class PreferencesWindowController: NSWindowController {
    private static var shared: PreferencesWindowController?
    private var escapeMonitor: Any?
    private var themeObserver: AnyCancellable?

    /// Show the preferences window as an app-modal dialog. Creates the
    /// controller on first call; reuses it on subsequent calls.
    ///
    /// `initialTab` — when non-nil, switches the Settings tab strip
    /// to that tab before showing the window. Used by callers like
    /// the disabled-state `AnnounceStatusButton`, which wants to
    /// open Settings directly to Time. nil keeps whatever tab was
    /// selected last (the default behavior).
    static func showPreferences(initialTab: SettingsTab? = nil) {
        if let tab = initialTab {
            SettingsNavigator.shared.selectedTab = tab
        }

        if shared == nil {
            shared = PreferencesWindowController()
        }

        guard let controller = shared else { return }

        controller.applyAppearance(SettingsManager.shared.settings.themePreference)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Install a local event monitor for Escape — NSHostingView swallows
        // the key event before it reaches the responder chain, so we
        // intercept at the event level instead. Galaxy uses the same trick.
        controller.escapeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { event in
            if event.keyCode == 53 {  // Escape
                controller.dismiss()
                return nil  // consume the event
            }
            return event
        }

        NSApp.runModal(for: controller.window!)

        // Runs after the modal event loop ends (dismiss was called).
        if let monitor = controller.escapeMonitor {
            NSEvent.removeMonitor(monitor)
            controller.escapeMonitor = nil
        }
    }

    private init() {
        // NSHostingController informs its window of SwiftUI's preferred
        // content size as the user switches tabs, enables days, or adds
        // time ranges. The default `sizingOptions` ([]) only propagates
        // grows reliably — shrinks can stall, leaving the window at the
        // tallest tab's height. Setting `.preferredContentSize` makes
        // the controller publish a fresh preferred size on every
        // SwiftUI layout pass, so the window tracks shrinks too. The
        // window opens at whatever size the initial SwiftUI content
        // wants and resizes from the top-left on every change.
        let settingsView = SettingsView()
            .environmentObject(SettingsManager.shared)
        let hostingController = NSHostingController(rootView: settingsView)
        hostingController.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable]
        window.title = "Settings"

        super.init(window: window)

        window.delegate = self
        window.center()

        // Apply initial appearance from current settings.
        applyAppearance(SettingsManager.shared.settings.themePreference)

        // Observe theme changes and update window.appearance without
        // recreating the view hierarchy.
        themeObserver = SettingsManager.shared.$settings
            .map(\.themePreference)
            .removeDuplicates()
            .sink { [weak self] newTheme in
                self?.applyAppearance(newTheme)
            }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Update the window's NSAppearance. Passing nil makes the window
    /// inherit the system appearance — that is how "Match system" works.
    private func applyAppearance(_ theme: ThemePreference) {
        window?.appearance = nsAppearance(for: theme)
    }

    private func nsAppearance(for theme: ThemePreference) -> NSAppearance? {
        switch theme {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    private func dismiss() {
        NSApp.stopModal()
        // orderOut instead of close — close triggers a window animation on
        // a background display-link thread that can crash if the controller
        // is deallocated mid-animation. Matches Galaxy's note.
        window?.orderOut(nil)
    }
}

// MARK: - NSWindowDelegate

extension PreferencesWindowController: NSWindowDelegate {
    /// Intercept the red X close button — redirect through dismiss() so we
    /// use orderOut (no animation) instead of the default close.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }
}
