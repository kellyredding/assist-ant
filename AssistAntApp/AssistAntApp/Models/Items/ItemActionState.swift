import Foundation

/// Pure aggregate of an action target (1..N items) — the state the shared
/// `ItemActions` cluster's buttons read. No SwiftUI, no I/O, so it lives in the
/// model layer and is exercised directly by ItemsSmoke. A single-item caller
/// (row hover, reader) passes `[item]`; the batch control bar passes the
/// selection.
struct ItemActionState {
    let count: Int
    /// Every target is resolved (resolved_at != nil).
    let allResolved: Bool
    /// Every target is iceboxed (iceboxed_at != nil). Drives the Icebox slot's
    /// label — which is invariant across resolve/restore; only its enabled
    /// state changes.
    let allIceboxed: Bool
    /// The resolve-button verb for the set (see `verb(for:)`).
    let resolveVerb: String

    init(_ items: [Item]) {
        count = items.count
        allResolved = !items.isEmpty && items.allSatisfy { $0.resolvedAt != nil }
        allIceboxed = !items.isEmpty && items.allSatisfy { $0.iceboxedAt != nil }
        resolveVerb = ItemActionState.verb(for: items)
    }

    /// "Done" for to-do/explore, "Dismiss" for reminder; the union joined when a
    /// batch mixes kinds (e.g. a to-do + a reminder → "Done / Dismiss").
    /// Reminders are the only "Dismiss" kind.
    static func verb(for items: [Item]) -> String {
        var hasDismiss = false
        var hasDone = false
        for item in items {
            if case .reminder = item.typeData { hasDismiss = true } else { hasDone = true }
        }
        switch (hasDone, hasDismiss) {
        case (true, true): return "Done / Dismiss"
        case (false, true): return "Dismiss"
        default: return "Done"
        }
    }
}
