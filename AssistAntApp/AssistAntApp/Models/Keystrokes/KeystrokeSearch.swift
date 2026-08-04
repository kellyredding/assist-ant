import Foundation

/// Filtering the ⌘/ cheat sheet against its search field.
///
/// Pure and Foundation-only, so the smoke target can assert what the sheet
/// decides. The rule used to live inline in the view, and that is why nobody
/// noticed it reading a whole row as one gap-anywhere subsequence: nothing could
/// reach it to check.
enum KeystrokeSearch {

    /// Everything a row puts on screen, all of it searchable.
    ///
    /// The section title and the condition are in here on purpose: typing
    /// "scratch" or "terminal" should turn up that part of the sheet, and those
    /// are the only places those words appear. They were briefly excluded because
    /// including them made short queries match almost the whole catalog — but
    /// that was the subsequence reading's fault, not theirs. Read as terms, a
    /// long condition can only answer to words it actually contains.
    struct Candidate: Equatable {
        let label: String
        let keys: String
        let section: String
        let condition: String
    }

    /// Where a query landed, so a row can show why it matched. Per field,
    /// because each is rendered separately; the section is a shared header and
    /// has nowhere to put a highlight.
    struct Hit: Equatable {
        var labelOffsets: [Int] = []
        var keysOffsets: [Int] = []
        var conditionOffsets: [Int] = []
    }

    /// Match every candidate, index-aligned with nil where one is filtered out.
    /// An empty query matches everything and highlights nothing.
    ///
    /// One rule, the note feed's: a query matches inside a word, and a space is
    /// the only way to cross one — it stands in for `.+`, so "th e" spans where
    /// "the" cannot. A row matches when any one of its fields does.
    ///
    /// Deliberately no second, looser pass. An earlier version fell back to
    /// gap-anywhere subsequence matching when nothing matched strictly, to keep
    /// initials like "mti" finding "Move to Icebox". It cost more than it bought:
    /// "scrat" matched "Leave input mode (discards the draft)" through five
    /// characters scattered over three words, and a search that answers a typo
    /// with a wrong row is worse than one that answers nothing. Initials are not
    /// worth a rule the reader cannot predict.
    static func hits(_ candidates: [Candidate], query: String) -> [Hit?] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return candidates.map { _ in Hit() } }
        return candidates.map { hit($0, query: trimmed) }
    }

    private static func hit(_ c: Candidate, query: String) -> Hit? {
        func offsets(_ field: String) -> [Int]? {
            FuzzyMatch.result(field, query: query, scope: .terms)?.matchedOffsets
        }
        let label = offsets(c.label)
        let keys = offsets(c.keys)
        let condition = offsets(c.condition)
        // The section matches without highlighting — it is drawn once above a
        // run of rows, so there is no per-row glyph to tint.
        let section = offsets(c.section)
        guard label != nil || keys != nil || condition != nil || section != nil
        else { return nil }
        return Hit(
            labelOffsets: label ?? [],
            keysOffsets: keys ?? [],
            conditionOffsets: condition ?? [])
    }
}
