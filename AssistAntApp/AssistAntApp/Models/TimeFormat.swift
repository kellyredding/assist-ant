import Foundation

/// User-selectable clock format. `dateFormat` is the DateFormatter pattern
/// the ClockView feeds into a formatter to render the current time.
enum TimeFormat: String, Codable, CaseIterable {
    case twelveHour
    case twentyFourHour

    var displayName: String {
        switch self {
        case .twelveHour: return "12-hour"
        case .twentyFourHour: return "24-hour"
        }
    }

    /// DateFormatter pattern. 12-hour mode includes "a" so AM/PM is rendered
    /// next to the digits; 24-hour mode omits it.
    var dateFormat: String {
        switch self {
        case .twelveHour: return "h:mm a"
        case .twentyFourHour: return "HH:mm"
        }
    }
}
