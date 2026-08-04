import Foundation
import Galactic
import KeyboardShortcuts

/// Turns a catalog binding into the text a row displays.
///
/// Nothing under `Models/Keystrokes/` imports `KeyboardShortcuts`, which is
/// what lets `KeystrokeCatalog` stay a Foundation-only value the smoke target
/// can compile — and this file sits one level up precisely so it can import
/// it. Six files in the app do; the constraint is about that directory, not
/// about this being the only importer. It is also what keeps the sheet honest:
/// the capture, status, and text-entry keystrokes are all user-configurable, so
/// they are read live here rather than frozen into the catalog where a rebind
/// would leave them lying.
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
            return labels(for: .submit)
        case .textEntryNewline:
            return labels(for: .newline)
        }
    }

    /// Galactic answers with the configured labels in the user's order, and
    /// with nothing at all when a list is empty — which is why the em dash is
    /// still here. The shared helper cannot know that a cheat-sheet row wants
    /// "not bound" spelled out where a composer placeholder wants silence, so
    /// it declines to guess and the caller decides.
    private static func labels(
        for action: TextEntryBindings.Action
    ) -> [String] {
        let labels = SettingsManager.shared.settings.textEntry
            .displayLabels(for: action)
        return labels.isEmpty ? [unbound] : labels
    }

    private static func shortcutText(_ name: KeyboardShortcuts.Name) -> String {
        KeyboardShortcuts.getShortcut(for: name)
            .map(String.init(describing:)) ?? unbound
    }
}
