import Foundation

/// Subsequence matching for the cheat sheet's filter field.
///
/// The corpus is under a hundred short strings, so ranking quality matters and
/// asymptotics do not: this walks the candidate once per query rather than
/// reaching for anything cleverer.
///
/// A row is searched as its label, its rendered keystroke, its section title,
/// and its condition joined together, so "icebox" finds Move to Icebox, "ai"
/// finds the `a i` chord, and "trash" finds everything scoped to that view.
enum KeystrokeFuzzyMatch {

    /// Points for a character that continues an unbroken run from the
    /// previous match. Runs are the strongest signal that the query is a
    /// prefix or substring rather than letters scattered across the string.
    private static let contiguousBonus = 8
    /// Points for a character landing at the start of a word.
    private static let wordStartBonus = 6
    /// Points for any matched character, so a longer match beats a shorter
    /// one when neither has structure to recommend it.
    private static let matchScore = 2
    /// Deducted per character skipped before the first match, so an earlier
    /// hit wins between two otherwise equal candidates. Capped so a long tail
    /// cannot drive a real match negative.
    private static let leadingPenalty = 1
    private static let maxLeadingPenalty = 12

    /// Score `candidate` against `query`, or nil when the query's characters
    /// do not all appear in order. Higher is better. Case-insensitive, and an
    /// empty query scores zero rather than failing, so an unfiltered sheet
    /// shows everything.
    static func score(_ candidate: String, query: String) -> Int? {
        let needle = Array(query.lowercased())
        guard !needle.isEmpty else { return 0 }

        let hay = Array(candidate.lowercased())
        guard needle.count <= hay.count else { return nil }

        var total = 0
        var needleIndex = 0
        var previousMatch: Int? = nil

        for (i, ch) in hay.enumerated() {
            guard needleIndex < needle.count, ch == needle[needleIndex] else {
                continue
            }

            total += matchScore
            if let previous = previousMatch, previous == i - 1 {
                total += contiguousBonus
            }
            if isWordStart(hay, i) {
                total += wordStartBonus
            }
            if previousMatch == nil {
                total -= min(i * leadingPenalty, maxLeadingPenalty)
            }

            previousMatch = i
            needleIndex += 1
        }

        guard needleIndex == needle.count else { return nil }
        return total
    }

    /// Whether the query matches at all. An empty query matches everything.
    static func matches(_ candidate: String, query: String) -> Bool {
        score(candidate, query: query) != nil
    }

    /// A character begins a word when it opens the string or follows a
    /// separator. Space-separated chords ("a i") count each key as a word
    /// start, which is what lets "ai" rank as a real hit rather than noise.
    private static func isWordStart(_ chars: [Character], _ i: Int) -> Bool {
        guard i > 0 else { return true }
        let previous = chars[i - 1]
        return previous == " " || previous == "-" || previous == "_"
            || previous == "/"
    }
}
