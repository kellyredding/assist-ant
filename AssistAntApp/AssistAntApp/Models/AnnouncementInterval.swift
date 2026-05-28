import Foundation

/// How often announcements fire when the schedule allows them. The user
/// picks one of these in Settings; the resulting `fireMinutes` set is the
/// minute-of-hour gate inside `AnnouncementService.shouldFire`.
enum AnnouncementInterval: String, Codable, CaseIterable {
    case hourly
    case halfHourly
    case quarterHourly

    var displayName: String {
        switch self {
        case .hourly:        return "On the hour"
        case .halfHourly:    return "On the half hour"
        case .quarterHourly: return "On the quarter hour"
        }
    }

    /// Minutes (0-59) within an hour at which the announcement fires.
    var fireMinutes: Set<Int> {
        switch self {
        case .hourly:        return [0]
        case .halfHourly:    return [0, 30]
        case .quarterHourly: return [0, 15, 30, 45]
        }
    }
}
