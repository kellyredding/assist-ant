import Foundation

/// One day in the agenda: its civil date and the calendar items on it
/// (sorted by start time; undated-start last). Empty days carry an empty
/// `items` so the view can still render a header + "no events".
struct AgendaDay: Identifiable, Equatable {
    let date: CivilDate
    let items: [Item]
    var id: String { date.iso }
}

/// Pure derivation of the agenda's day sections. No SwiftUI, no I/O —
/// mirrors `TodayCalendar`.
enum ScheduleAgenda {
    /// Every day from `start` through the last day carrying an event (or
    /// `start` itself if none), inclusive — empty days included — each with
    /// its sorted items. `items` is the already-range-fetched set.
    static func days(items: [Item], from start: CivilDate) -> [AgendaDay] {
        let grouped = Dictionary(grouping: items) { item in
            item.scheduledOn ?? CivilDate(item.createdAt)
        }
        let lastEventDay = grouped.keys.max() ?? start
        let end = max(lastEventDay, start)

        var out: [AgendaDay] = []
        var cursor = start
        while cursor <= end {
            let dayItems = (grouped[cursor] ?? []).sorted { lhs, rhs in
                (startAt(lhs) ?? .distantFuture) < (startAt(rhs) ?? .distantFuture)
            }
            out.append(AgendaDay(date: cursor, items: dayItems))
            cursor = cursor.adding(days: 1)
        }
        return out
    }

    /// The calendar payload's start instant, if any.
    static func startAt(_ item: Item) -> Date? {
        if case .calendar(let d) = item.typeData { return d.startAt }
        return nil
    }

    /// Past once the event's end (or start) is at/behind `now`. Drives the
    /// dimmed styling, same rule as the today sidebar.
    static func isPast(_ item: Item, now: Date) -> Bool {
        guard case .calendar(let d) = item.typeData else { return false }
        guard let end = d.endAt ?? d.startAt else { return false }
        return end < now
    }
}
