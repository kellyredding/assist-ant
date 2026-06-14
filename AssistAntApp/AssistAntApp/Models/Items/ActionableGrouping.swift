import Foundation

/// One named (or unnamed) list of actionable items. `listName == nil` is the
/// "no list" group, rendered first. `id` is stable for ForEach + collapse
/// tracking.
struct ActionableGroup: Identifiable, Equatable {
    let listName: String?
    let items: [Item]
    var isNamed: Bool { listName != nil }
    var id: String { listName ?? "\u{0}__no_list__" }
}

/// Pure derivation of an actionable list's sections. No SwiftUI, no I/O.
enum ActionableGrouping {
    /// Group `items` into: the no-list group first, then named lists ordered
    /// case-insensitively A→Z. A named list appears only when at least one item
    /// carries it — empty lists never render, since the groups derive from the
    /// items present. Within each group, newest-iceboxed first (nil iceboxed
    /// last), then id.
    static func groups(items: [Item]) -> [ActionableGroup] {
        let grouped = Dictionary(grouping: items) { $0.actionableListName }

        func sortedItems(_ items: [Item]) -> [Item] {
            items.sorted { lhs, rhs in
                switch (lhs.iceboxedAt, rhs.iceboxedAt) {
                case let (l?, r?) where l != r: return l > r   // newest first
                case (nil, _?): return false                   // nils last
                case (_?, nil): return true
                default: return lhs.id < rhs.id                // stable tiebreak
                }
            }
        }

        var out: [ActionableGroup] = []
        if let noList = grouped[nil], !noList.isEmpty {
            out.append(ActionableGroup(listName: nil, items: sortedItems(noList)))
        }
        let named = grouped
            .compactMap { key, value in key.map { ($0, value) } }
            .sorted { ActionableListSort.less($0.0, $1.0) }
        for (name, items) in named {
            out.append(ActionableGroup(listName: name, items: sortedItems(items)))
        }
        return out
    }
}

extension Item {
    /// The actionable list name, normalized (trimmed; empty → nil). The
    /// grouping key. Non-actionable items have no list name.
    var actionableListName: String? {
        let raw: String?
        switch typeData {
        case .todo(let d), .reminder(let d), .explore(let d): raw = d.listName
        default: raw = nil
        }
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// The actionable external URL (Linear issue link, etc.), if any.
    var actionableExternalURL: String? {
        switch typeData {
        case .todo(let d), .reminder(let d), .explore(let d): return d.externalURL
        default: return nil
        }
    }
}
