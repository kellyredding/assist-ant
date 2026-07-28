import SwiftUI

/// Bridges a recorded keystroke to SwiftUI's `KeyboardShortcut`, for the
/// composers that cannot intercept `keyDown`.
///
/// SwiftUI's `TextEditor` exposes no key handling, so a view built on it can
/// only reach the keyboard through `.keyboardShortcut` on a hidden button. That
/// modifier names exactly one chord, which is why the settings' list has to be
/// spread across one button per entry rather than expressed in a single call.
///
/// Kept out of the shared `Keystroke.swift` on purpose: that file is
/// Foundation-only so the smoke target can link it without AppKit, and it is
/// byte-identical to the companion app's copy. This helper is neither.
extension Keystroke {
    /// The SwiftUI shortcut this keystroke names, or nil when `KeyEquivalent`
    /// has no spelling for the key.
    ///
    /// Nil is returned rather than guessed at. A shortcut built from the wrong
    /// key would fire on a keystroke the user never chose, which is worse than
    /// one that does not fire at all — the second is visible the first time it
    /// is tried.
    var keyboardShortcut: KeyboardShortcut? {
        guard let equivalent = keyEquivalent else { return nil }
        var modifiers: EventModifiers = []
        if self.modifiers.contains(.command) { modifiers.insert(.command) }
        if self.modifiers.contains(.option) { modifiers.insert(.option) }
        if self.modifiers.contains(.control) { modifiers.insert(.control) }
        if self.modifiers.contains(.shift) { modifiers.insert(.shift) }
        return KeyboardShortcut(equivalent, modifiers: modifiers)
    }

    private var keyEquivalent: KeyEquivalent? {
        switch keyCode {
        case Key.ret, Key.keypadEnter: return .return
        case 48: return .tab
        case 49: return .space
        case 51: return .delete
        case 53: return .escape
        case 115: return .home
        case 116: return .pageUp
        case 117: return .deleteForward
        case 119: return .end
        case 121: return .pageDown
        case 123: return .leftArrow
        case 124: return .rightArrow
        case 125: return .downArrow
        case 126: return .upArrow
        default:
            // Letters and digits address themselves. Lowercased, because an
            // uppercase equivalent implies Shift to SwiftUI and would add a
            // modifier nobody asked for — the same trap `claudeKeyName` avoids.
            guard let label = Self.keyTable[keyCode]?.label,
                  label.count == 1,
                  let character = label.lowercased().first,
                  character.isLetter || character.isNumber
            else { return nil }
            return KeyEquivalent(character)
        }
    }
}

extension TextEntryBindings {
    /// Shortcuts for every configured submit keystroke that SwiftUI can express.
    ///
    /// A list rather than one, because the settings allow several and a view that
    /// honoured only the first would disagree with every composer that reads the
    /// bindings properly.
    var submitShortcuts: [KeyboardShortcut] {
        submit.compactMap(\.keyboardShortcut)
    }
}
