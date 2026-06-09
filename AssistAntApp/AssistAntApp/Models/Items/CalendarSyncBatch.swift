import Foundation

/// The batch the `assist-ant calendar-item sync` CLI writes to a temp file and
/// hands the app (by path) in a `calendar_item.sync` envelope. The app applies
/// every item plus the window prune in one atomic transaction, then deletes
/// the file. Keys match the CLI's JSON exactly.
struct CalendarSyncBatch: Codable {
    struct ItemRow: Codable {
        let externalID: String
        let title: String
        let startAt: String      // ISO-8601, verbatim from the provider
        let scheduledOn: String  // local civil date, derived by the CLI
        let endAt: String?
        let timeZone: String?
        let body: String

        enum CodingKeys: String, CodingKey {
            case externalID = "external_id"
            case title
            case startAt = "start_at"
            case scheduledOn = "scheduled_on"
            case endAt = "end_at"
            case timeZone = "time_zone"
            case body
        }
    }

    let source: String
    let from: String
    let to: String
    let prune: Bool
    let keep: [String]
    let items: [ItemRow]
}
