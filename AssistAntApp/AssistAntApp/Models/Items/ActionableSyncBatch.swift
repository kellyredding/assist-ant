import Foundation

/// The batch the `assist-ant actionable-item sync` CLI writes to a temp file
/// and hands the app in an `actionable_item.sync` envelope. The app applies
/// every row (create / update / resolve) plus an orphan reconcile in one atomic
/// transaction, then deletes the file. Keys match the CLI's JSON exactly;
/// identity is `(workspace, source, external_id)`.
struct ActionableSyncBatch: Codable {
    struct ItemRow: Codable {
        let externalID: String
        let title: String
        let body: String
        let url: String              // → ActionableData.externalURL
        let statusType: String       // started | unstarted | backlog | completed
        let completedAt: String?     // ISO-8601, present only for completed issues

        enum CodingKeys: String, CodingKey {
            case externalID = "external_id"
            case title
            case body
            case url
            case statusType = "status_type"
            case completedAt = "completed_at"
        }
    }

    let source: String          // "linear"
    let reconcile: Bool         // soft-delete orphans not in `keep`? (false on a partial fetch)
    let keep: [String]          // every external_id seen this sync
    let items: [ItemRow]
}
