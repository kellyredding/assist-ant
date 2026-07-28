import AppKit
import SwiftUI

/// Calls `action` when one of the configured submit keystrokes is pressed, using
/// a local key monitor rather than a hidden button's key equivalent.
///
/// The distinction is not stylistic. A key equivalent cannot win a modifier-less
/// Return against a focused text editor: the editor takes it as input first, so a
/// user who binds submit to plain Return gets newlines and no save. ⌘Return hides
/// the problem, because a modified Return is not text input and nothing competes
/// for it — which is exactly why this went unnoticed until someone configured
/// Return on its own.
///
/// A local monitor runs before the event reaches the responder chain, so it sees
/// the keystroke whatever holds focus. That is how the actionable item editor has
/// always worked; this brings the views built on SwiftUI's `TextEditor` — which
/// exposes no key handling of its own — to the same place.
///
/// Attach only while a composer is actually open. The monitor is app-wide while
/// installed, and swallowing a submit keystroke that some other view meant to
/// handle would be worse than the problem it solves.
struct SubmitKeyMonitor: ViewModifier {
    let action: () -> Void

    @ObservedObject private var settingsManager = SettingsManager.shared
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: install)
            .onDisappear(perform: remove)
            // Rebuilt when the bindings change, so an edit session that is
            // already open follows the new keystroke rather than the one that
            // was configured when it opened.
            .onChange(of: settingsManager.settings.textEntry) { _, _ in
                remove()
                install()
            }
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard SettingsManager.shared.settings.textEntry
                .action(for: Keystroke(event: event)) == .submit
            else { return event }
            action()
            return nil
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension View {
    /// Run `action` on the configured submit keystroke, for composers that
    /// cannot intercept `keyDown` themselves.
    func onSubmitKeystroke(_ action: @escaping () -> Void) -> some View {
        modifier(SubmitKeyMonitor(action: action))
    }
}
