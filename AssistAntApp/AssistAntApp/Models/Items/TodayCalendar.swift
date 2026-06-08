import Foundation

/// One calendar row in the today sidebar: the item plus whether it has already
/// ended relative to "now" (drives the dimmed past-event styling).
struct TodayCalendarRow: Identifiable, Equatable {
    let item: Item
    let isPast: Bool
    var id: String { item.id }
}

/// Pure derivation of the today sidebar's calendar rows from the active
/// calendar items and the current instant. No SwiftUI, no I/O — unit-testable.
enum TodayCalendar {
    /// Active calendar items whose `scheduledOn` is today (in `timeZone`),
    /// sorted by start time (undated last), each flagged past if it has ended.
    static func rows(
        items: [Item], now: Date, timeZone: TimeZone = .current
    ) -> [TodayCalendarRow] {
        let today = CivilDate(now, in: timeZone)
        let todays = items.filter { $0.scheduledOn == today }
        let sorted = todays.sorted { lhs, rhs in
            let l = startAt(lhs) ?? Date.distantFuture
            let r = startAt(rhs) ?? Date.distantFuture
            return l < r
        }
        return sorted.map { item in
            TodayCalendarRow(item: item, isPast: isPast(item, now: now))
        }
    }

    /// The calendar payload's start instant, if any.
    static func startAt(_ item: Item) -> Date? {
        if case .calendar(let d) = item.typeData { return d.startAt }
        return nil
    }

    /// Past once the event's end (or its start, if no end) is at/behind `now`.
    static func isPast(_ item: Item, now: Date) -> Bool {
        guard case .calendar(let d) = item.typeData else { return false }
        guard let end = d.endAt ?? d.startAt else { return false }
        return end < now
    }
}
