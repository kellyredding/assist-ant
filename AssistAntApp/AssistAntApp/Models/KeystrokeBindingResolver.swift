import Foundation
import Galactic
import KeyboardShortcuts

/// Turns a catalog binding into the text a row displays.
///
/// The only place that imports `KeyboardShortcuts`, which is what lets
/// `KeystrokeCatalog` stay a Foundation-only value the smoke target can
/// compile. It is also what keeps the sheet honest: the capture, status, and
/// text-entry keystrokes are all user-configurable, so they are read live here
/// rather than frozen into the catalog where a rebind would leave them lying.
enum KeystrokeBindingResolver {

    /// Shown when a rebindable keystroke has nothing assigned. A dash reads as
    /// "not bound"; an empty cell reads as a rendering bug.
    static let unbound = "—"

    /// Every keystroke bound to `binding`, in the order Settings lists them: one
    /// for a fixed key, as many as are configured for a rebindable one, and a
    /// single dash when a rebindable one has nothing.
    ///
    /// All of them, which is where this parts company with the composer hints it
    /// used to borrow. Those name only the first, and rightly — a placeholder
    /// listing three chords has stopped being a hint. A reference that names one
    /// of three is a different thing: the other two work, and the sheet was
    /// denying they existed.
    static func displayTexts(for binding: KeystrokeBinding) -> [String] {
        switch binding {
        case .literal(let text):
            return [text]
        case .capture(let kind):
            return [shortcutText(KeyboardShortcuts.Name.capture(for: kind))]
        case .statusPopover:
            return [shortcutText(.statusPopover)]
        case .textEntryCommit:
            return labels(SettingsManager.shared.settings.textEntry.submit)
        case .textEntryNewline:
            return labels(SettingsManager.shared.settings.textEntry.newline)
        }
    }

    private static func labels(_ keystrokes: [Keystroke]) -> [String] {
        keystrokes.isEmpty ? [unbound] : keystrokes.map(\.displayLabel)
    }

    private static func shortcutText(_ name: KeyboardShortcuts.Name) -> String {
        KeyboardShortcuts.getShortcut(for: name)
            .map(String.init(describing:)) ?? unbound
    }
}
