import Foundation

/// The mutations the shared actions cluster invokes, wired by the host model so
/// the cluster needn't reference any one surface's model or snapshot. Each
/// returns the updated rows; a single-item caller reads the first for its
/// onChange. The host (Icebox today, Schedule next) supplies closures bound to
/// its own in-place snapshot mutations.
struct ActionableActions {
    var complete: ([Item]) -> [Item]
    var reopen: ([Item]) -> [Item]
    var moveToIcebox: ([Item]) -> [Item]
    var removeFromIcebox: ([Item]) -> [Item]
    var reclassify: ([Item], ItemType) -> [Item]
    var setListName: ([Item], String?) -> [Item]
}
