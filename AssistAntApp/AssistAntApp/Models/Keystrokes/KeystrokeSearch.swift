import Foundation

/// Filtering the ⌘/ cheat sheet against its search field.
///
/// Pure and Foundation-only, so the smoke target can assert what the sheet
/// decides. The rule used to live inline in the view, and that is why nobody
/// noticed it reading the condition text: nothing could reach it to check.
enum KeystrokeSearch {

    /// One row's searchable text: the label and the keystroke, and deliberately
    /// nothing else.
    ///
    /// The section title and the availability condition are display, not
    /// haystack. They are long, they repeat verbatim across dozens of rows, and
    /// folding them in made a gap-anywhere match very nearly a tautology — every
    /// selection-gated row ends in "Schedule, Icebox, Trash, with a selection",
    /// which donates enough letters that "del" matched all of them and "cl"
    /// matched almost the whole catalog.
    struct Candidate: Equatable {
        let label: String
        let keys: String
    }

    /// Where a query landed, so a row can show why it matched.
    struct Hit: Equatable {
        var labelOffsets: [Int] = []
        var keysOffsets: [Int] = []
    }

    /// Match every candidate, index-aligned with nil where one is filtered out.
    /// An empty query matches everything and highlights nothing.
    ///
    /// Two passes, and the second runs only when the first matched nothing at
    /// all anywhere.
    ///
    /// The strict pass reads the label as whitespace-separated terms — the
    /// scratch feed's rule, because a label is prose too — and the keystroke as
    /// a subsequence, so "ai" still finds the `a i` chord and "ll" the `l l`.
    /// Together they answer a word query exactly: "del" returns the Delete rows
    /// and nothing else.
    ///
    /// The relaxed pass re-reads the label as a subsequence, which is how
    /// initials work: "mti" is not a term of "Move to Icebox" but is a
    /// subsequence of it. Running it only over an otherwise-empty result is what
    /// keeps initials without paying for them on every query — a gap-anywhere
    /// match is worth its noise when the alternative is no answer, and not
    /// otherwise.
    static func hits(_ candidates: [Candidate], query: String) -> [Hit?] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return candidates.map { _ in Hit() } }

        let strict = candidates.map { strictHit($0, query: trimmed) }
        if strict.contains(where: { $0 != nil }) { return strict }
        return candidates.map { relaxedHit($0, query: trimmed) }
    }

    /// Label as ordered terms, keystroke as a subsequence. Either one hitting is
    /// a match, and both contribute their offsets when both hit.
    private static func strictHit(_ c: Candidate, query: String) -> Hit? {
        let label = FuzzyMatch.result(c.label, query: query, scope: .terms)
        let keys = FuzzyMatch.result(c.keys, query: query, scope: .subsequence)
        guard label != nil || keys != nil else { return nil }
        return Hit(
            labelOffsets: label?.matchedOffsets ?? [],
            keysOffsets: keys?.matchedOffsets ?? [])
    }

    /// Label as a subsequence — initials, and only when nothing was found.
    private static func relaxedHit(_ c: Candidate, query: String) -> Hit? {
        guard let label = FuzzyMatch.result(
            c.label, query: query, scope: .subsequence)
        else { return nil }
        return Hit(labelOffsets: label.matchedOffsets)
    }
}
