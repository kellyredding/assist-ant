import Foundation

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

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let parts = raw.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid CivilDate '\(raw)' (expected YYYY-MM-DD)"
            )
        }
        self.init(year: y, month: m, day: d)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(iso)
    }
}
