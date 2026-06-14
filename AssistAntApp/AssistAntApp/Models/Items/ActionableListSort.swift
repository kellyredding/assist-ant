import Foundation

/// Ordering for actionable list names that sorts by the name's *text*, not by a
/// leading emoji or decorative symbol. "🐜 AA" sorts ahead of "★ Galaxy" because
/// "AA" < "Galaxy"; a name that is *only* glyphs (no letters/numbers) falls back
/// to sorting by the glyphs and lands after every text-bearing name.
///
/// Pure (no SwiftUI/I/O), so it is unit-testable and shared by every list-name
/// sort site: ActionableGrouping (Today / Icebox / Schedule), the store's
/// knownListNames (capture picker + list editor), and the list-editor search
/// tiebreak.
enum ActionableListSort {
    /// Strict ordering: true when `a` should sort before `b`.
    static func less(_ a: String, _ b: String) -> Bool {
        let ka = key(for: a)
        let kb = key(for: b)
        if ka.glyphOnly != kb.glyphOnly {
            return !ka.glyphOnly            // text-bearing names first
        }
        switch ka.text.localizedCaseInsensitiveCompare(kb.text) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame:
            // Same comparison key (e.g. "🐜 AA" vs "★ AA") — stable, deterministic
            // tiebreak on the original name.
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    /// The comparison key: the name with emoji + decorative symbols removed,
    /// trimmed. When that is empty the name is glyph-only, so the key is the
    /// original name and `glyphOnly` is true (sorts after text-bearing names).
    static func key(for name: String) -> (text: String, glyphOnly: Bool) {
        let text = name
            .filter { !$0.isDecorativeGlyph }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? (name, true) : (text, false)
    }
}

private extension Character {
    /// An emoji or a standalone pictographic symbol (Unicode "Symbol, Other") —
    /// the decorative glyphs ignored when sorting list names. Letters, numbers,
    /// marks, punctuation, currency, and math symbols are kept.
    var isDecorativeGlyph: Bool {
        unicodeScalars.contains { scalar in
            let p = scalar.properties
            // `isEmoji` is true for bare ASCII digits / # / * too, so require
            // emoji presentation or a multi-scalar cluster (VS16 / ZWJ seq) to
            // count it as an emoji glyph; "So" catches non-emoji symbols (★, ♥).
            let isEmojiGlyph =
                p.isEmoji && (p.isEmojiPresentation || unicodeScalars.count > 1)
            return isEmojiGlyph || p.generalCategory == .otherSymbol
        }
    }
}
