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
    /// Every day from `start` through the last day carrying an item (or `start`/
    /// `today`, whichever is later, if none), inclusive — empty days included.
    /// Each day splits its items into calendar events (time-sorted) and
    /// actionables (grouped into sublists). `items` is the already-range-fetched
    /// set; resolved actionables are kept so they render struck as history.
    ///
    /// Days are assigned by `bucket(for:today:)`: open unscheduled/overdue
    /// actionables roll onto `today` (mirroring the Today sidebar), while
    /// resolved and future-scheduled actionables — and all calendar events —
    /// anchor to their own scheduled day.
    static func days(items: [Item], from start: CivilDate, today: CivilDate) -> [AgendaDay] {
        let grouped = Dictionary(grouping: items) { bucket(for: $0, today: today) }
        let lastDay = grouped.keys.max() ?? start
        let end = [lastDay, start, today].max()!

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

    /// The agenda day an item renders on. Calendar events and resolved
    /// actionables anchor to their scheduled day (history); an item with no
    /// scheduled day falls back to its creation day. An OPEN actionable mirrors
    /// the Today sidebar's surfacing rule: unscheduled or overdue (scheduled
    /// on/before `today`) rolls forward onto `today`, while a future-scheduled
    /// one stays on its day. This keeps the schedule's today column consistent
    /// with the Today list, which shows the same unscheduled/overdue items.
    static func bucket(for item: Item, today: CivilDate) -> CivilDate {
        guard !isCalendar(item), item.resolvedAt == nil else {
            return item.scheduledOn ?? CivilDate(item.createdAt)
        }
        guard let scheduled = item.scheduledOn else { return today }
        return scheduled <= today ? today : scheduled
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
