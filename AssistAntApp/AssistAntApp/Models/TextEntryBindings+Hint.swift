import Foundation

/// Hint text for the native composers, derived from the live bindings.
///
/// Kept out of `TextEntryBindings` itself so that file stays byte-identical to
/// the companion app's copy. The companion app needs no Swift equivalent: every
/// composer it has is a WebView, so its hints come from `placeholderHint` in the
/// JavaScript twin. These two derivations answer the same question in the two
/// places that ask it, which is why both read the binding rather than repeating
/// a string.
extension TextEntryBindings {
    /// The submit keystroke to advertise, or nil when nothing is bound.
    ///
    /// The first in the list rather than all of them: a hint naming three chords
    /// has stopped being a hint. Order is the user's own, so the first entry is
    /// the one they put first.
    var submitHint: String? { submit.first?.displayLabel }

    /// The newline keystroke to advertise, or nil when nothing is bound.
    var newlineHint: String? { newline.first?.displayLabel }

    /// The trailing half of a composer's hint: which key inserts a newline,
    /// which one commits, and how to get out.
    ///
    /// An unbound half is dropped rather than rendered empty. Advertising a
    /// keystroke that does nothing is worse than not mentioning one — the same
    /// rule the JavaScript hint follows.
    func hintClauses(verb: String) -> [String] {
        var clauses: [String] = []
        if let newlineHint { clauses.append("\(newlineHint) for newline") }
        if let submitHint { clauses.append("\(submitHint) to \(verb)") }
        return clauses
    }
}
