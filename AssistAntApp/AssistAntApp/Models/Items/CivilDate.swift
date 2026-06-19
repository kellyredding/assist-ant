import Foundation
import GRDB

/// A timezone-free calendar date (`YYYY-MM-DD`). Use for `*_on` fields whose
/// meaning is "what day the user meant", independent of any time zone — e.g.
/// a to-do's `scheduledOn` or a reminder's `startingOn`. Storing such values
/// as a UTC `Date` instant causes off-by-one-day bugs across time zones; a
/// zoneless civil date avoids that by construction.
///
/// Encodes to/from the JSON string "YYYY-MM-DD".
struct CivilDate: Codable, Equatable, Hashable, Comparable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The civil date as it appears in `timeZone` (defaults to the current
    /// zone) at the given instant.
    init(_ date: Date, in timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// "YYYY-MM-DD".
    var iso: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func < (lhs: CivilDate, rhs: CivilDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// Parse "YYYY-MM-DD". Reused by Codable decoding and by the app's
    /// calendar-item handler.
    init?(iso: String) {
        let parts = iso.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = CivilDate(iso: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid CivilDate '\(raw)' (expected YYYY-MM-DD)"
            )
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(iso)
    }
}

/// Calendar arithmetic for the agenda's week jumps and day iteration. All go
/// through a gregorian Calendar in the current zone (Monday-first), then back
/// to a zoneless CivilDate, so week math matches what the user sees locally.
extension CivilDate {
    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        c.firstWeekday = 2  // Monday, so mondayOfWeek anchors correctly
        return c
    }

    /// Noon on this civil date in the current zone — a safe instant for
    /// arithmetic and for feeding DateFormatter (month/weekday display).
    var noon: Date {
        Self.calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: 12)
        ) ?? Date()
    }

    /// This date shifted by `days` (may be negative).
    func adding(days: Int) -> CivilDate {
        let shifted = Self.calendar.date(byAdding: .day, value: days, to: noon)
            ?? noon
        return CivilDate(shifted)
    }

    /// The Monday of the week containing this date.
    func mondayOfWeek() -> CivilDate {
        guard let start = Self.calendar
            .dateInterval(of: .weekOfYear, for: noon)?.start
        else { return self }
        return CivilDate(start)  // firstWeekday = 2 ⇒ start is Monday
    }

    /// The Monday on or after the first day of next month.
    func firstMondayOfNextMonth() -> CivilDate {
        let cal = Self.calendar
        guard let firstOfThis = cal.date(
                from: DateComponents(year: year, month: month, day: 1)),
              let firstOfNext = cal.date(byAdding: .month, value: 1, to: firstOfThis)
        else { return self }
        var d = firstOfNext
        while cal.component(.weekday, from: d) != 2 {   // 2 == Monday
            d = cal.date(byAdding: .day, value: 1, to: d) ?? d
        }
        return CivilDate(d)
    }

    /// Today as a civil date in the current zone.
    static var today: CivilDate { CivilDate(Date()) }

    /// The first day of this date's month.
    func firstOfMonth() -> CivilDate { CivilDate(year: year, month: month, day: 1) }

    /// The first of the month `n` months from this date's month (n may be
    /// negative). Used to page the reschedule calendar.
    func addingMonths(_ n: Int) -> CivilDate {
        let cal = Self.calendar
        let base = cal.date(from: DateComponents(year: year, month: month, day: 1)) ?? noon
        return CivilDate(cal.date(byAdding: .month, value: n, to: base) ?? base)
    }
}

/// Persisted as a `TEXT` "YYYY-MM-DD" value — SQLite has no native date type,
/// matching Galaxy's convention of storing dates/timestamps as TEXT.
extension CivilDate: DatabaseValueConvertible {
    var databaseValue: DatabaseValue { iso.databaseValue }

    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> CivilDate? {
        String.fromDatabaseValue(dbValue).flatMap(CivilDate.init(iso:))
    }
}

/// The preset reschedule targets offered in the reschedule panel, in display
/// order. Each resolves to a concrete future civil date from a reference
/// "today"; the panel adds an ad-hoc date picker after these.
enum RescheduleOption: CaseIterable, Identifiable {
    case today               // pull a future item back to today
    case tomorrow
    case dayAfterTomorrow
    case nextWeek            // Monday of next week
    case sameDayNextWeek
    case nextMonth           // first Monday of the following month

    var id: Self { self }

    var title: String {
        switch self {
        case .today: return "Today"
        case .tomorrow: return "Tomorrow"
        case .dayAfterTomorrow: return "Day after tomorrow"
        case .nextWeek: return "Next week"
        case .sameDayNextWeek: return "Same day next week"
        case .nextMonth: return "Next month"
        }
    }

    func resolved(from today: CivilDate) -> CivilDate {
        switch self {
        case .today: return today
        case .tomorrow: return today.adding(days: 1)
        case .dayAfterTomorrow: return today.adding(days: 2)
        case .nextWeek: return today.mondayOfWeek().adding(days: 7)
        case .sameDayNextWeek: return today.adding(days: 7)
        case .nextMonth: return today.firstMondayOfNextMonth()
        }
    }
}
