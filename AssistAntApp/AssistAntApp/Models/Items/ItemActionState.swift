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
    /// Every target is soft-deleted (`deletedAt != nil`). Drives the ⋮ menu /
    /// trash pill flip between Delete and Put back, mirroring `allIceboxed`.
    let allDeleted: Bool
    /// Every target is synced from an external source (`externalID != nil`).
    /// Drives the Delete / Put back disable: sync owns a synced item's
    /// lifecycle, so those actions are disabled (with a tooltip) for it.
    let allSynced: Bool
    /// The resolve-button verb for the set (see `verb(for:)`).
    let resolveVerb: String

    init(_ items: [Item]) {
        count = items.count
        allResolved = !items.isEmpty && items.allSatisfy { $0.resolvedAt != nil }
        allIceboxed = !items.isEmpty && items.allSatisfy { $0.iceboxedAt != nil }
        allDeleted = !items.isEmpty && items.allSatisfy { $0.deletedAt != nil }
        allSynced = !items.isEmpty && items.allSatisfy { $0.isSynced }
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

/// Reschedule eligibility. An item is reschedulable on its own only when it's an
/// actionable kind (not a calendar event), not soft-deleted, and not iceboxed —
/// scheduling an icebox item makes no sense (take it out first). The cluster
/// offers reschedule when ANY target qualifies; a batch then applies the date to
/// every selected actionable, including a held iceboxed/trashed member swept into
/// a Schedule selection (it keeps its state and gains the future day — the fields
/// are orthogonal).
enum RescheduleEligibility {
    static func canReschedule(_ item: Item) -> Bool {
        guard item.deletedAt == nil, item.iceboxedAt == nil else { return false }
        if case .calendar = item.typeData { return false }
        return true
    }
}
