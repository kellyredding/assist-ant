import Foundation

/// The set of item kinds AssistAnt understands today. Stored as the raw string
/// in the `type` column of the items table. Kinds outside this set (e.g. a
/// future type introduced by the backend and seen by an older client) are not
/// listed here — they are carried losslessly as `ItemTypeData.unknown` while
/// keeping their original `type` string.
enum ItemType: String, Codable, CaseIterable, Sendable {
    case calendar
    case todo
    case reminder
    case explore
}
