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

    /// Show the editor prefilled with `currentName` (the shared list name, or
    /// nil for "Add to list" / a mixed selection), block until dismissed, and
    /// return the chosen outcome. The caller applies it (via IceboxModel) so the
    /// store mutation stays in the action layer.
    static func present(currentName: String?) -> ListEditorOutcome {
        ListEditorWindowController(currentName: currentName).runModalForOutcome()
    }

    private init(currentName: String?) {
        let current = currentName
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

/// What the user chose in the Reschedule panel.
enum RescheduleOutcome {
    case cancel
    case date(CivilDate)
}

/// The reschedule panel's window. It drives Return/Escape/Tab/arrows from its
/// own event monitor, so a key that reaches the window unhandled is expected —
/// swallow it instead of letting `NSWindow` ring the unhandled-key beep. (Keys a
/// focused control wants — typing in the M/D/Y field — are handled by that
/// responder before they ever reach the window.)
private final class RescheduleWindow: NSWindow {
    override func keyDown(with event: NSEvent) { /* swallow — no NSBeep */ }
}

/// Hosts `RescheduleEditorView` as a draggable, app-modal window centered over
/// the main window and returns the chosen day synchronously — the same idiom as
/// `ListEditorWindowController` (the change-list editor the ⋮ menu / `ll` chord
/// open), so reschedule presents consistently from the menu, the `ls` chord, and
/// the batch bar.
final class RescheduleEditorWindowController: NSWindowController, NSWindowDelegate {
    private let model: RescheduleEditorModel
    private var outcome: RescheduleOutcome = .cancel
    private var keyMonitor: Any?

    /// Show the panel, block until dismissed, and return the chosen outcome. The
    /// caller applies it (via the host model) so the store mutation stays in the
    /// action layer.
    static func present() -> RescheduleOutcome {
        RescheduleEditorWindowController().runModalForOutcome()
    }

    private init() {
        let model = RescheduleEditorModel(today: .today)
        self.model = model

        let window = RescheduleWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Reschedule"

        super.init(window: window)
        window.delegate = self

        let view = RescheduleEditorView(
            model: model,
            onPick: { [weak self] day in self?.finish(.date(day)) },
            onCancel: { [weak self] in self?.finish(.cancel) }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
        hosting.view.layoutSubtreeIfNeeded()
        window.setContentSize(hosting.view.fittingSize)

        applyAppearance(SettingsManager.shared.settings.themePreference)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func runModalForOutcome() -> RescheduleOutcome {
        positionOverMainWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // The panel's keyboard driver: NSHostingView swallows keys before the
        // responder chain, so the model is driven at the event level (the same
        // trick the List editor uses for Escape).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in self?.handleKey(event) ?? event
        }

        NSApp.runModal(for: window!)

        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        return outcome
    }

    /// The panel's keyboard model, while this window is key. Returns nil to
    /// consume the key. Esc/Return always act; Tab moves the option list and the
    /// arrows drive the calendar (in "Pick a date…") — unless the M/D/Y stepper
    /// field is being edited, in which case those keys are its own.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let window, NSApp.keyWindow === window else { return event }
        switch event.keyCode {
        case 53: scheduleFinish(.cancel); return nil                       // Escape
        case 36, 76: scheduleFinish(.date(model.resolvedDate)); return nil // Return / Enter
        default: break
        }
        // Let the focused M/D/Y stepper field own Tab / arrows / typing.
        if window.firstResponder is NSText { return event }
        if event.keyCode == 48 {                                   // Tab / ⇧Tab
            model.moveSelection(event.modifierFlags.contains(.shift) ? -1 : 1)
            return nil
        }
        if model.isPick {
            switch event.keyCode {
            case 126: model.nudgeDay(-7); return nil   // ↑ : back a week
            case 125: model.nudgeDay(7);  return nil   // ↓ : forward a week
            case 123: model.nudgeDay(-1); return nil   // ← : back a day
            case 124: model.nudgeDay(1);  return nil   // → : forward a day
            default: break
            }
        }
        return event
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

    private func finish(_ outcome: RescheduleOutcome) {
        self.outcome = outcome
        NSApp.stopModal()
        window?.orderOut(nil)
    }

    /// End the modal from a key handler on the NEXT modal-loop pass, after the
    /// keyDown has already been consumed (`return nil`). Ending the modal
    /// mid-dispatch is what rang the unhandled-key beep on Return.
    private func scheduleFinish(_ outcome: RescheduleOutcome) {
        RunLoop.current.perform(inModes: [.modalPanel, .default]) { [weak self] in
            self?.finish(outcome)
        }
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
