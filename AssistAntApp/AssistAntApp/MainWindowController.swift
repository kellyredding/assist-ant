import AppKit
import SwiftUI
import Combine

/// Main AssistAnt window. Hosts ContentView. Reports close via the onClose
/// callback so ActivationPolicyManager can flip back to .accessory when
/// the last window closes. Subscribes to SettingsManager.$settings so the
/// window appearance follows the user's theme preference live.
///
/// Theme observer mirrors Galaxy's MainWindowController
/// (~/projects/kellyredding/galaxy/GalaxyApp/GalaxyApp/MainWindowController.swift).
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void
    private var themeObserver: AnyCancellable?

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose

        let hosting = NSHostingController(rootView: ContentView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "AssistAnt"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 480, height: 320))
        window.center()
        window.isReleasedWhenClosed = false

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
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

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
}
