import Foundation

/// Refreshes the snapshot list surfaces (Icebox + Schedule + Trash) so a
/// mutation on one surface — or in the reader, which routes through them — keeps
/// the others current. `except` skips the surface that originated the change: it
/// already updated in place, and reloading it would drop its undo-until-refresh
/// state. The Today sidebar observes the store live (not a snapshot), so it is
/// never refreshed here.
@MainActor
enum ActionableSnapshots {
    static func refresh(except origin: MainTab? = nil) {
        if origin != .icebox { IceboxModel.shared.refresh() }
        if origin != .schedule { ScheduleAgendaModel.shared.refresh() }
        if origin != .trash { TrashModel.shared.refresh() }
    }
}
