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
    static func showPreferences() {
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"

        super.init(window: window)

        window.delegate = self

        // Hosting view sized to fit the SwiftUI content. Created once and
        // never recreated so the theme observer can update window appearance
        // without rebuilding the view hierarchy.
        let settingsView = SettingsView()
            .environmentObject(SettingsManager.shared)
        let hostingView = NSHostingView(rootView: settingsView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = hostingView

        let fittingSize = hostingView.fittingSize
        window.setContentSize(fittingSize)
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
