import AppKit
import SwiftUI

/// What the user chose in the List editor.
enum ListEditorOutcome {
    case cancel
    case save(String)
    case remove
}

/// Hosts `ListEditorView` as a draggable, app-modal window and returns the
/// user's choice synchronously. Mirrors `PreferencesWindowController`, but
/// positions the window centered over the app's MAIN window (like Galaxy's
/// New-marker sheet) instead of NSWindow's default display-centered placement —
/// so it opens where the user is looking. One instance per presentation (it
/// carries a result), unlike the reused preferences window.
final class ListEditorWindowController: NSWindowController, NSWindowDelegate {
    private var outcome: ListEditorOutcome = .cancel
    private var escapeMonitor: Any?

    /// Show the editor for `item`, block until dismissed, and return the chosen
    /// outcome. The caller applies it (via IceboxModel) so the store mutation
    /// stays in the action layer.
    static func present(for item: Item) -> ListEditorOutcome {
        ListEditorWindowController(item: item).runModalForOutcome()
    }

    private init(item: Item) {
        let current = item.actionableListName
        let known = (try? GRDBItemStore.shared.knownListNames()) ?? []

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = current == nil ? "Add to list" : "Change list"

        super.init(window: window)
        window.delegate = self

        let view = ListEditorView(
            currentListName: current,
            knownNames: known,
            onSave: { [weak self] name in self?.finish(.save(name)) },
            onRemove: { [weak self] in self?.finish(.remove) },
            onCancel: { [weak self] in self?.finish(.cancel) }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
        // Force an initial layout so the window adopts the content's size
        // before we position it over the main window.
        hosting.view.layoutSubtreeIfNeeded()
        window.setContentSize(hosting.view.fittingSize)

        applyAppearance(SettingsManager.shared.settings.themePreference)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func runModalForOutcome() -> ListEditorOutcome {
        positionOverMainWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // NSHostingView swallows Escape before the responder chain, so catch it
        // at the event level — same trick the preferences window uses.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if event.keyCode == 53 {   // Escape
                self?.finish(.cancel)
                return nil
            }
            return event
        }

        NSApp.runModal(for: window!)

        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
        return outcome
    }

    /// Center over the app's main window (fallback: key window, then screen).
    private func positionOverMainWindow() {
        guard let window else { return }
        let parent = NSApp.mainWindow
            ?? NSApp.keyWindow
            ?? NSApp.windows.first { $0.isVisible && $0 !== window }
        guard let parent else { window.center(); return }
        let p = parent.frame
        let s = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: p.midX - s.width / 2,
            y: p.midY - s.height / 2
        ))
    }

    private func finish(_ outcome: ListEditorOutcome) {
        self.outcome = outcome
        NSApp.stopModal()
        // orderOut instead of close — close triggers a background-thread window
        // animation that can crash if the controller deallocates mid-animation.
        window?.orderOut(nil)
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(.cancel)
        return false
    }

    // MARK: - Appearance

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
}
