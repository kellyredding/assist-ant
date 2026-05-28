import Foundation

/// Which kind of minute boundary the current time is on. Independent of
/// the user's AnnouncementInterval — the boundary type is derived from
/// the actual minute and decides how many times the chosen sound chimes,
/// while the interval setting decides which boundaries fire at all.
///
/// Westminster-style doubling pattern: quarter (1) → half (2) → top (4).
enum AnnouncementBoundary {
    case topOfHour      // :00 — 4 chimes
    case halfHour       // :30 — 2 chimes
    case quarterHour    // :15 or :45 — 1 chime

    /// Returns the boundary type for `minute` (0-59), or nil if `minute`
    /// is not on a quarter-hour boundary.
    static func from(minute: Int) -> AnnouncementBoundary? {
        switch minute {
        case 0:       return .topOfHour
        case 30:      return .halfHour
        case 15, 45:  return .quarterHour
        default:      return nil
        }
    }

    /// How many times to play the chosen sound at this boundary.
    var soundCount: Int {
        switch self {
        case .topOfHour:    return 4
        case .halfHour:     return 2
        case .quarterHour:  return 1
        }
    }
}
