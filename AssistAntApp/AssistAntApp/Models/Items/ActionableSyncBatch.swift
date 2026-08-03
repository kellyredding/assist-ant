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
        let statusType: String       // started | unstarted | backlog | triage | completed
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

    /// Override for the full-turnover guard — set only by
    /// `--allow-full-turnover`, for a real Linear-side migration where every
    /// identifier legitimately changed at once.
    ///
    /// Optional so a payload written before the flag existed still decodes; the
    /// absent case reads as false, which is the safe default (let the guard do
    /// its job).
    let allowFullTurnover: Bool?

    enum CodingKeys: String, CodingKey {
        case source
        case reconcile
        case keep
        case items
        case allowFullTurnover = "allow_full_turnover"
    }
}

/// What a sync actually did, as distinct from what the CLI intended.
///
/// It exists because the CLI cannot know: it hands over a batch and never sees
/// the store, so before this its summary reported `reconcile=true` from its own
/// intent whether or not reconcile ran. A withheld retirement is the one outcome
/// that must reach the operator, so the sync now answers with what happened.
struct ActionableSyncOutcome {
    enum WithheldReason: String {
        /// Nothing qualified upstream at all.
        case emptyFetch
        /// A non-empty fetch that matched none of the rows reconcile could
        /// retire — the shape of the 2026-08-03 mass-delete.
        case fullTurnover
    }

    /// Rows reconcile was entitled to retire, sampled before any upsert.
    var priorCandidates = 0
    var retired = 0
    var reconcileWithheld = false
    var withheldReason: WithheldReason?
}
