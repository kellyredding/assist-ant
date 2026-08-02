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

    static func displayText(for binding: KeystrokeBinding) -> String {
        switch binding {
        case .literal(let text):
            return text
        case .capture(let kind):
            return shortcutText(KeyboardShortcuts.Name.capture(for: kind))
        case .statusPopover:
            return shortcutText(.statusPopover)
        case .textEntryCommit:
            return SettingsManager.shared.settings.textEntry.submitHint
                ?? unbound
        case .textEntryNewline:
            return SettingsManager.shared.settings.textEntry.newlineHint
                ?? unbound
        }
    }

    private static func shortcutText(_ name: KeyboardShortcuts.Name) -> String {
        KeyboardShortcuts.getShortcut(for: name)
            .map(String.init(describing:)) ?? unbound
    }
}
