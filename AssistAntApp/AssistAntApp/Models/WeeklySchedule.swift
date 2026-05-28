import Foundation

/// Day of the week with a Calendar-compatible weekday number
/// (1 = Sunday, 2 = Monday, ..., 7 = Saturday) so the trigger logic can
/// match Calendar.current.component(.weekday, from:) directly.
enum Weekday: Int, Codable, CaseIterable {
    case sunday = 1
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday

    var displayName: String {
        switch self {
        case .sunday:    return "Sunday"
        case .monday:    return "Monday"
        case .tuesday:   return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday:  return "Thursday"
        case .friday:    return "Friday"
        case .saturday:  return "Saturday"
        }
    }

    /// Monday-first ordering for the schedule editor UI. `allCases` stays
    /// in Calendar order (Sunday-first) because the trigger logic looks
    /// up days by `Calendar.weekday` raw value (1 = Sunday).
    static let displayOrder: [Weekday] = [
        .monday, .tuesday, .wednesday, .thursday, .friday,
        .saturday, .sunday
    ]
}

/// Hour + minute pair, no timezone. Comparable on (hour, minute). The
/// trigger logic always evaluates these against `Calendar.current` so
/// schedule values are intentionally local-time wall-clock values — the
/// 9 AM in a saved entry means 9 AM in whatever timezone the system is
/// currently set to.
struct TimeOfDay: Codable, Equatable, Comparable, Hashable {
    var hour: Int      // 0-23
    var minute: Int    // 0-59

    static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        if lhs.hour != rhs.hour { return lhs.hour < rhs.hour }
        return lhs.minute < rhs.minute
    }

    /// True if `self` falls within `[start, end]` inclusive on both ends.
    /// Inclusive end means "8 AM to 5 PM" fires at 8, 9, ..., 16, 17 with
    /// hourly interval (10 fires total). Matches casual "from X to Y"
    /// speech.
    func isWithin(_ start: TimeOfDay, _ end: TimeOfDay) -> Bool {
        return self >= start && self <= end
    }
}

/// One announcement window: e.g. 8:00 AM through 10:00 AM.
struct TimeRange: Codable, Equatable, Identifiable {
    var id: UUID
    var start: TimeOfDay
    var end: TimeOfDay

    /// Factory for a fresh 9 AM – 5 PM range with a new UUID. Used as the
    /// default value when the user clicks "Add time range". A static `let`
    /// would hand out the same UUID every time and break SwiftUI's
    /// ForEach identity — so this is a `static var` that mints a fresh
    /// instance on each access.
    static var newWorkdayDefault: TimeRange {
        TimeRange(
            id: UUID(),
            start: TimeOfDay(hour: 9, minute: 0),
            end:   TimeOfDay(hour: 17, minute: 0)
        )
    }
}

/// One day's slice of the schedule.
struct DaySchedule: Codable, Equatable {
    var enabled: Bool
    var ranges: [TimeRange]

    static let empty = DaySchedule(enabled: false, ranges: [])
}

/// Full weekly schedule. Keyed by Weekday so the UI can iterate in any
/// order without a fixed property name per day. The trigger logic looks
/// up today's day directly: `schedule.days[weekday]`.
struct WeeklySchedule: Codable, Equatable {
    var days: [Weekday: DaySchedule]

    static let empty: WeeklySchedule = {
        var dict: [Weekday: DaySchedule] = [:]
        for day in Weekday.allCases {
            dict[day] = .empty
        }
        return WeeklySchedule(days: dict)
    }()

    /// Monday–Friday enabled with a single 9 AM – 5 PM range each;
    /// Saturday and Sunday disabled. The default shipped via
    /// `AnnouncementSettings.defaults` so first-time users see a sensible
    /// workday pattern as soon as they enable announcements.
    static var workdayDefault: WeeklySchedule {
        var dict: [Weekday: DaySchedule] = [:]
        for day in Weekday.allCases {
            switch day {
            case .monday, .tuesday, .wednesday, .thursday, .friday:
                dict[day] = DaySchedule(
                    enabled: true,
                    ranges: [.newWorkdayDefault]
                )
            case .saturday, .sunday:
                dict[day] = .empty
            }
        }
        return WeeklySchedule(days: dict)
    }

    /// True if today's DaySchedule is enabled AND `time` falls within any
    /// of its ranges. Empty range list (or disabled day) returns false.
    func isActive(at time: TimeOfDay, weekday: Weekday) -> Bool {
        guard let day = days[weekday], day.enabled else { return false }
        return day.ranges.contains { range in
            time.isWithin(range.start, range.end)
        }
    }
}
