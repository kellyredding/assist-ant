import Foundation
import Combine

enum ItemStoreError: Error {
    /// `upsert` keys on `external_id`; an item without one must use `create`.
    case upsertRequiresExternalID
    /// A window `pruneMissing` was attempted with an empty keep set and without
    /// an explicit opt-in. Refused, because an empty keep set retires every
    /// in-window item — almost always the symptom of a degraded or empty
    /// upstream fetch, not an intentional "clear the window."
    case emptyKeepPruneRefused
    /// `reclassify` is only valid among the actionable kinds (todo/reminder/
    /// explore); calendar has an incompatible payload.
    case reclassifyRequiresActionable
}

/// The seam the rest of the app uses to read and mutate items. A GRDB-backed
/// local implementation exists today; the sync engine plugs in behind this
/// same protocol later.
protocol ItemStore {
    func create(_ item: Item) throws
    func update(_ item: Item) throws

    /// Insert-or-update keyed on `(workspace, source, external_id)`. Resurrects a
    /// soft-deleted row (clears `deletedAt`) and refreshes values; preserves the
    /// existing `id` and `createdAt`. Requires a non-nil `externalID`.
    func upsert(_ item: Item) throws

    func softDelete(id: String) throws

    /// Toggle icebox membership: stamp or clear `iceboxed_at`. Preserves
    /// `scheduled_on` — the icebox flag supersedes the schedule for display, so
    /// removing from the icebox restores the item to its day (or Today when it
    /// has none). Backs the Move to / Remove from Icebox action.
    func setIceboxed(id: String, _ iceboxed: Bool) throws

    /// Window-scoped reconcile: soft-delete active items for `source` whose
    /// `scheduledOn` is within `[from, to]` and whose `externalID` is not in
    /// `keep`. Items outside the window are untouched. An empty `keep` would
    /// retire the whole window, so it is refused with `emptyKeepPruneRefused`
    /// unless `allowEmptyKeep` is set (the explicit "yes, clear it" opt-in).
    func pruneMissing(
        workspaceID: String, source: String,
        from: CivilDate, to: CivilDate, keep: Set<String>,
        allowEmptyKeep: Bool
    ) throws

    func fetch(id: String) throws -> Item?

    /// Active items: not soft-deleted and not iceboxed. `type == nil` = all types.
    func fetchActive(type: ItemType?) throws -> [Item]

    /// Active items of `type` (nil = all) whose `scheduled_on` falls in
    /// [from, to]. `to == nil` means unbounded forward. Excludes rows with no
    /// `scheduled_on`. Ordered by day then id.
    func fetchActive(type: ItemType?, from: CivilDate, to: CivilDate?) throws -> [Item]

    /// Reactive stream of active items, re-emitted on every relevant DB change.
    func observeActive(type: ItemType?) -> AnyPublisher<[Item], Error>

    /// Active actionable items (todo/reminder/explore) that surface on `today`:
    /// not deleted/iceboxed/resolved, and either unscheduled or scheduled
    /// on/before today (overdue accumulates). Sorted by manual `position`, then
    /// `scheduled_on`, then `id`; nulls last in each.
    func fetchActionable(asOf today: CivilDate) throws -> [Item]

    /// Reactive form of `fetchActionable`. `today` is fixed at subscription;
    /// re-subscribing at the local midnight rollover is the caller's concern.
    func observeActionable(asOf today: CivilDate) -> AnyPublisher<[Item], Error>

    /// Mark an item resolved (`resolved_at = now`) or active again (clears it).
    func resolve(id: String) throws
    func unresolve(id: String) throws

    /// Set or clear the scheduled day. A future day drops it off today; nil
    /// makes it always-today.
    func reschedule(id: String, to scheduledOn: CivilDate?) throws

    /// Save the user-editable title and body in one write. The title is
    /// trimmed and required — a blank title is ignored (the existing one is
    /// kept); the body trims, and a blank value clears it to NULL. A local
    /// edit — on a synced item the next sync still refreshes both from
    /// upstream.
    func setTitleAndBody(id: String, title: String, body: String?) throws

    /// Swap an actionable item's kind, preserving payload/identity/schedule/
    /// resolution/position. Throws `reclassifyRequiresActionable` if the item
    /// or the target is not actionable.
    func reclassify(id: String, to type: ItemType) throws

    /// Iceboxed actionable items (todo/reminder/explore) that are active and
    /// unresolved: deleted_at IS NULL, iceboxed_at IS NOT NULL, resolved_at IS
    /// NULL. Ordered newest-iceboxed first, then id. The Icebox view groups
    /// these by list name.
    func fetchIceboxed() throws -> [Item]

    /// Complete an actionable: stamp resolved_at = now and scheduled_on = the
    /// completion day, leaving iceboxed_at untouched so the completion stays
    /// reversible from the icebox. The general mark-done / mark-dismissed path.
    func completeActionable(id: String) throws

    /// Reverse a completion: clear resolved_at, and clear scheduled_on when the
    /// item is iceboxed (an active iceboxed item carries no schedule). The undo
    /// for an accidental complete.
    func reopenActionable(id: String) throws

    /// Set or clear an actionable item's list name (nil or blank clears it),
    /// preserving the kind and the external URL. No-op for a non-actionable
    /// item.
    func setListName(id: String, to listName: String?) throws

    /// Distinct, non-empty list names currently in use by non-deleted
    /// actionable items, sorted case-insensitively. Derived live (no stored
    /// table) so a name with no remaining items drops off on its own.
    func knownListNames() throws -> [String]
}
