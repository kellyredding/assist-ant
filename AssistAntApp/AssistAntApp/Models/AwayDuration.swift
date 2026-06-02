import Foundation

/// Preset spans for the "Away from desk" menu. Mirrors `MuteDuration` but
/// is a separate type because the two features are independent and away
/// adds an `endOfDay` option. Unlike a fixed `timeInterval`, the target is
/// computed from `now` (so `endOfDay` can resolve to local midnight).
enum AwayDuration: CaseIterable, Identifiable {
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case twoHours
    case fourHours
    case eightHours
    case endOfDay

    var id: Self { self }

    var displayName: String {
        switch self {
        case .fifteenMinutes: return "15 minutes"
        case .thirtyMinutes:  return "30 minutes"
        case .oneHour:        return "1 hour"
        case .twoHours:       return "2 hours"
        case .fourHours:      return "4 hours"
        case .eightHours:     return "8 hours"
        case .endOfDay:       return "End of day"
        }
    }

    /// The wall-clock instant the away window ends, computed from `now`.
    /// Fixed durations add their length; `endOfDay` resolves to local
    /// midnight (the start of the next day).
    func until(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .fifteenMinutes: return now.addingTimeInterval(15 * 60)
        case .thirtyMinutes:  return now.addingTimeInterval(30 * 60)
        case .oneHour:        return now.addingTimeInterval(60 * 60)
        case .twoHours:       return now.addingTimeInterval(2 * 60 * 60)
        case .fourHours:      return now.addingTimeInterval(4 * 60 * 60)
        case .eightHours:     return now.addingTimeInterval(8 * 60 * 60)
        case .endOfDay:
            let startOfToday = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: 1, to: startOfToday)
                ?? now.addingTimeInterval(8 * 60 * 60)
        }
    }
}
