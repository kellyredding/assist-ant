import Foundation

/// One named (or unnamed) group of scratch entries. `listName == nil` is the
/// "no list" group, rendered first and with no header text — a thought parked
/// without filing it is the default case, not a category.
///
/// Generic over the element rather than fixed to `Item` because the feed renders
/// rows that pair a note with the offsets its search matched, and those offsets
/// have to survive grouping or the highlight goes dark the moment a query
/// narrows the feed. Grouping only ever reads the element's list name, which the
/// caller supplies, so it never has to know what else a row carries.
struct ScratchGroup<Element>: Identifiable {
    let listName: String?
    let entries: [Element]
    var isNamed: Bool { listName != nil }
    var id: String { listName ?? ScratchGrouping.noListID }
}

/// Pure derivation of the scratch feed's sections. Foundation only — no
/// SwiftUI, no Combine, no store — so ItemsSmoke exercises the ordering.
enum ScratchGrouping {
    /// The no-list group's stable id, for ForEach and collapse tracking.
    ///
    /// Its own sentinel rather than `ActionableGroup`'s: collapse state is a
    /// per-surface `Set<String>`, and one shared id would mean that the day such
    /// a set is lifted somewhere common — or persisted — collapsing the unfiled
    /// notes also collapsed the unfiled to-dos. The leading NUL keeps it out of
    /// reach of any name that can be typed into the list editor.
    static let noListID = "\u{0}__scratch_no_list__"

    /// Group `entries` into: the no-list group first, then named lists ordered
    /// by `ActionableListSort` — so a leading emoji is ignored and the headings
    /// read in the same order as the schedule's and the icebox's. A named group
    /// exists only when an entry carries it, so an emptied list stops rendering
    /// on its own.
    ///
    /// Order WITHIN a group is the incoming order, untouched. The feed arrives
    /// newest-captured first (newest-resolved for the completed set) and that
    /// chronology is how you find a note again; notes carry no drag `position`
    /// to re-sort by, which is the whole difference from `ActionableGrouping`.
    /// `Dictionary(grouping:)` appends into each bucket in sequence order, so a
    /// bucket comes out in feed order — relied on rather than re-imposed, and
    /// pinned by a smoke check because it is the one property here with no sort
    /// of its own to fall back on.
    static func groups<Element>(
        _ entries: [Element], listName: (Element) -> String?
    ) -> [ScratchGroup<Element>] {
        let grouped = Dictionary(grouping: entries, by: listName)

        var out: [ScratchGroup<Element>] = []
        if let noList = grouped[nil], !noList.isEmpty {
            out.append(ScratchGroup(listName: nil, entries: noList))
        }
        let named = grouped
            .compactMap { key, value in key.map { ($0, value) } }
            .sorted { ActionableListSort.less($0.0, $1.0) }
        for (name, entries) in named {
            out.append(ScratchGroup(listName: name, entries: entries))
        }
        return out
    }
}

extension Item {
    /// The scratch note's list name, normalized (trimmed; empty → nil) — the
    /// scratch feed's grouping key. Nil for every other kind.
    ///
    /// Deliberately NOT folded into `actionableListName`. That accessor is what
    /// `ActionableGrouping` groups by, and `fetchTrashed` hands Trash both notes
    /// and actionables through it — so teaching it about scratch would
    /// re-section the Trash, re-key its collapse set, change its j/k order, and
    /// prefill a note's list into the actionable list editor. A note's list
    /// belongs to the note's own feed; Trash keeps filing notes as unlisted.
    var scratchListName: String? {
        guard case .scratch(let d) = typeData else { return nil }
        let trimmed = d.listName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }
}
