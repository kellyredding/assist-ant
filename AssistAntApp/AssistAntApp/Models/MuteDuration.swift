import Foundation

/// The six preset durations exposed by the mute menu. Kept as an enum
/// (not raw `TimeInterval` values) so the display strings and the
/// underlying interval stay in sync at one definition site, and so
/// the in-window button and the menu bar item iterate the same source
/// of truth.
enum MuteDuration: CaseIterable, Identifiable {
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case twoHours
    case fourHours
    case eightHours

    var id: Self { self }

    var displayName: String {
        switch self {
        case .fifteenMinutes: return "15 minutes"
        case .thirtyMinutes:  return "30 minutes"
        case .oneHour:        return "1 hour"
        case .twoHours:       return "2 hours"
        case .fourHours:      return "4 hours"
        case .eightHours:     return "8 hours"
        }
    }

    var timeInterval: TimeInterval {
        switch self {
        case .fifteenMinutes: return 15 * 60
        case .thirtyMinutes:  return 30 * 60
        case .oneHour:        return 60 * 60
        case .twoHours:       return 2 * 60 * 60
        case .fourHours:      return 4 * 60 * 60
        case .eightHours:     return 8 * 60 * 60
        }
    }
}
