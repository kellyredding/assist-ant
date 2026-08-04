import AppKit
import SwiftUI
import Galactic

/// Resolves the configured submit and newline keystrokes for a composer, using a
/// local key monitor scoped to the composer's own window.
///
/// A monitor rather than the alternatives, because neither alternative covers the
/// whole setting:
///
/// - **`keyDown` on an NSTextView we own** never sees a Command-modified key.
///   AppKit dispatches those through `performKeyEquivalent` and the menu, so a
///   user who binds submit to ⌘Return gets nothing at all.
/// - **A key equivalent on a hidden button** is the mirror image: it catches
///   ⌘Return, and cannot take a bare Return away from a focused text editor,
///   which claims it as input first.
///
/// Each of those failures shipped once. A local monitor runs before the event is
/// dispatched at all, so it sees every keystroke the settings might name.
///
/// The window check is what makes that safe. A local monitor is app-wide while
/// installed, so an unscoped one belonging to an open item editor would swallow
/// the submit keystroke of a capture popover floating above it — one press, two
/// actions, and the visible one not the one intended.
struct TextEntryKeyMonitor: ViewModifier {
    /// Invoked for the submit keystroke.
    let onSubmit: () -> Void
    /// Whether this composer wants newline handled too. False where the surface
    /// has no multi-line field to insert into.
    var handlesNewline: Bool = true
    /// When false, no monitor is installed at all.
    ///
    /// The window check below is not enough when two composers live in the *same*
    /// window — a pane's composer and a row being edited inline. Both monitors
    /// match the keystroke, the submit branch consumes it unconditionally, and
    /// whichever AppKit happens to call first wins. That reads as the submit
    /// keystroke working intermittently. Callers that can have two composers up
    /// use this to keep exactly one live.
    var isEnabled: Bool = true

    @ObservedObject private var settingsManager = SettingsManager.shared
    @State private var monitor: Any?
    @State private var window: NSWindow?

    func body(content: Content) -> some View {
        content
            .background(WindowReader { window = $0 })
            .onAppear(perform: install)
            .onDisappear(perform: remove)
            // Reinstalled when the bindings change, so a composer that is already
            // open follows the new keystrokes rather than the ones configured
            // when it opened.
            .onChange(of: settingsManager.settings.textEntry) { _, _ in
                remove()
                install()
            }
            // Track the flag so a composer that stands down mid-life actually
            // tears its monitor out rather than holding the keystroke.
            .onChange(of: isEnabled) { _, enabled in
                if enabled { install() } else { remove() }
            }
    }

    private func install() {
        guard isEnabled, monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Events bound for another window are none of this composer's
            // business, even while its monitor is alive.
            guard let window, event.window === window else { return event }
            // The cheat sheet opens inside the composer's own window, so the
            // check above passes while it is up — and submitting the composer
            // underneath is not what the submit key means with a reference sheet
            // on top of it.
            guard !KeystrokeSheetModel.isClaimingKeyboard else { return event }

            switch SettingsManager.shared.settings.textEntry
                .action(for: Keystroke(event: event))
            {
            case .submit:
                onSubmit()
                return nil
            case .newline:
                guard handlesNewline,
                      let text = window.firstResponder as? NSTextView,
                      text.isEditable
                else { return event }
                // Inserted explicitly because the keystroke bound to newline may
                // be one AppKit would do nothing with. Routed through the action
                // method so it joins the undo stack like typed text.
                text.insertNewline(nil)
                return nil
            case nil:
                return event
            }
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Reports the `NSWindow` hosting a SwiftUI view, so a key monitor can tell its
/// own window's events from every other window's.
private struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Read after the view joins a hierarchy: `window` is nil until then.
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(view.window) }
    }
}

extension View {
    /// Resolve the configured submit and newline keystrokes for this composer.
    func onTextEntryKeystrokes(
        enabled: Bool = true,
        handlesNewline: Bool = true,
        onSubmit: @escaping () -> Void
    ) -> some View {
        modifier(
            TextEntryKeyMonitor(
                onSubmit: onSubmit, handlesNewline: handlesNewline,
                isEnabled: enabled))
    }
}
