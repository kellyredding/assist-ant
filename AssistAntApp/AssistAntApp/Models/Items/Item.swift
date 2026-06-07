import Foundation
import GRDB

/// A tracked item — the single polymorphic record behind every item type.
/// Shared columns are stored properties; the type-specific payload lives in
/// `typeData`, stored as JSON in the `type_data` column.
///
/// `serverUpdatedAt` and `pending` are sync bookkeeping, not surfaced in the
/// UI: `pending` is the outbox flag ("has un-pushed local changes"), and
/// `serverUpdatedAt` records the server's `updated_at` for the version this row
/// is reconciled with (nil until first synced).
///
/// Column names are pinned via explicit snake_case `CodingKeys` (GRDB derives
/// column names from the coding keys), avoiding any reliance on automatic
/// camelCase→snake_case conversion for acronym-suffixed names like `tenantID`.
struct Item: Codable, Equatable, FetchableRecord, PersistableRecord {
    var id: String                 // UUIDv7, client-minted
    var tenantID: String
    var type: String               // == typeData.kind (denormalized for SQL filters)
    var title: String
    var body: String?              // markdown
    var source: String             // "manual" | "gcal" | "linear" | ...
    var externalID: String?        // source key for the identity index; nil for manual
    var typeData: ItemTypeData     // stored as JSON in `type_data`
    var iceboxedAt: Date?          // UTC instant
    var deletedAt: Date?           // UTC tombstone
    var scheduledOn: CivilDate?    // local civil date; cross-type schedule key
    var createdAt: Date            // UTC; locally stamped pre-sync, server post-sync
    var updatedAt: Date            // UTC; the sync-cursor source once syncing
    var serverUpdatedAt: Date?     // server's updated_at for the reconciled version
    var pending: Bool              // has un-pushed local changes

    static let databaseTableName = "items"

    enum CodingKeys: String, CodingKey {
        case id
        case tenantID = "tenant_id"
        case type
        case title
        case body
        case source
        case externalID = "external_id"
        case typeData = "type_data"
        case iceboxedAt = "iceboxed_at"
        case deletedAt = "deleted_at"
        case scheduledOn = "scheduled_on"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case serverUpdatedAt = "server_updated_at"
        case pending
    }
}
