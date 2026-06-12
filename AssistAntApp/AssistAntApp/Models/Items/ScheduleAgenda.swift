import Foundation

/// One day in the agenda: its civil date, the calendar events on it (sorted by
/// start; undated-start last), and the day's actionable items grouped into
/// sublists (no-list first, then named A→Z). Empty days carry empty halves so
/// the view can still render a header.
struct AgendaDay: Identifiable, Equatable {
    let date: CivilDate
    let events: [Item]
    let actionableGroups: [ActionableGroup]
    var id: String { date.iso }
}

/// Pure derivation of the agenda's day sections. No SwiftUI, no I/O.
enum ScheduleAgenda {
    /// Every day from `start` through the last day carrying an item (or `start`
    /// itself if none), inclusive — empty days included. Each day splits its
    /// items into calendar events (time-sorted) and actionables (grouped into
    /// sublists). `items` is the already-range-fetched set; resolved actionables
    /// are kept so they render struck as history.
    static func days(items: [Item], from start: CivilDate) -> [AgendaDay] {
        let grouped = Dictionary(grouping: items) { item in
            item.scheduledOn ?? CivilDate(item.createdAt)
        }
        let lastDay = grouped.keys.max() ?? start
        let end = max(lastDay, start)

        var out: [AgendaDay] = []
        var cursor = start
        while cursor <= end {
            let dayItems = grouped[cursor] ?? []
            let events = dayItems
                .filter { isCalendar($0) }
                .sorted { (startAt($0) ?? .distantFuture) < (startAt($1) ?? .distantFuture) }
            let actionables = dayItems.filter { !isCalendar($0) }
            out.append(AgendaDay(
                date: cursor,
                events: events,
                actionableGroups: ActionableGrouping.groups(items: actionables)))
            cursor = cursor.adding(days: 1)
        }
        return out
    }

    /// Whether the item is a calendar event (vs an actionable todo/reminder/
    /// explore). Calendar events render with time columns; actionables render as
    /// the shared list rows.
    static func isCalendar(_ item: Item) -> Bool {
        if case .calendar = item.typeData { return true }
        return false
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
