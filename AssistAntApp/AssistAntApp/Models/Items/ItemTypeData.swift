import Foundation

/// Type-specific payload for a `calendar` item.
struct CalendarData: Codable, Equatable, Sendable {
    var startAt: Date?        // UTC instant; nil for all-day or undated events
    var endAt: Date?          // UTC instant
    var allDay: Bool = false
    var timeZoneID: String?   // IANA id (e.g. "America/Los_Angeles") for timed events
}

/// Type-specific payload for a `todo` item.
struct TodoData: Codable, Equatable, Sendable {
    var listName: String?         // optional grouping into a named list
    var scheduledOn: CivilDate?   // the day this is scheduled for (zoneless)
    var completedAt: Date?        // UTC instant when completed; nil while open
}

/// Type-specific payload for a `reminder` item.
struct ReminderData: Codable, Equatable, Sendable {
    var listName: String?
    var startingOn: CivilDate?    // day to begin surfacing the reminder (zoneless)
    var dismissedAt: Date?        // UTC instant when dismissed; nil while active
}

/// Type-specific payload for an `explore` item.
struct ExploreData: Codable, Equatable, Sendable {
    var listName: String?
    var externalURL: String?      // linked article / resource
    var addedOn: CivilDate?       // day added (zoneless)
    var completedAt: Date?        // UTC instant when explored/completed
}

/// The polymorphic payload stored in an item's `type_data` JSON column. Each
/// case maps to an `ItemType`; `.unknown` preserves the raw payload of a kind
/// this build doesn't recognize, so forward/backward compatibility holds (an
/// older client round-trips a newer server's item type without data loss).
///
/// Serializes as `{ "kind": "<type>", "data": { ...payload... } }`. The item
/// row's `type` column is the denormalized discriminator (== `kind`), used for
/// SQL filtering.
enum ItemTypeData: Equatable, Sendable {
    case calendar(CalendarData)
    case todo(TodoData)
    case reminder(ReminderData)
    case explore(ExploreData)
    case unknown(kind: String, payload: JSONValue)

    /// The discriminator string for this payload (matches the item's `type`).
    var kind: String {
        switch self {
        case .calendar: return ItemType.calendar.rawValue
        case .todo: return ItemType.todo.rawValue
        case .reminder: return ItemType.reminder.rawValue
        case .explore: return ItemType.explore.rawValue
        case .unknown(let kind, _): return kind
        }
    }
}

extension ItemTypeData: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch ItemType(rawValue: kind) {
        case .calendar:
            self = .calendar(try container.decode(CalendarData.self, forKey: .data))
        case .todo:
            self = .todo(try container.decode(TodoData.self, forKey: .data))
        case .reminder:
            self = .reminder(try container.decode(ReminderData.self, forKey: .data))
        case .explore:
            self = .explore(try container.decode(ExploreData.self, forKey: .data))
        case nil:
            self = .unknown(
                kind: kind,
                payload: try container.decode(JSONValue.self, forKey: .data)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .calendar(let data): try container.encode(data, forKey: .data)
        case .todo(let data): try container.encode(data, forKey: .data)
        case .reminder(let data): try container.encode(data, forKey: .data)
        case .explore(let data): try container.encode(data, forKey: .data)
        case .unknown(_, let payload): try container.encode(payload, forKey: .data)
        }
    }
}
