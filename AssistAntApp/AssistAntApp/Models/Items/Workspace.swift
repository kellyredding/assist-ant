import Foundation
import GRDB

/// The single workspace this install belongs to. A workspace is an *install
/// identity*: every item row is scoped to it via `items.workspace_id`. There is
/// exactly one per desktop install — seated once by the database migration and
/// never switched. Multiple mobile clients may later attach to the same
/// workspace; multi-workspace switching is a future mobile-client concern, not
/// a desktop one.
///
/// The record lives in `items.db` alongside the rows it scopes (not in
/// prefs.json) so identity travels with the data: via the consistent backup
/// snapshot today, via the sync backend later.
///
/// `id` is an opaque, immutable UUID and the only value written to
/// `items.workspace_id` (and, later, used as the sync scope key). It is
/// deliberately not a secret. `name` is a freely-editable display label;
/// renaming touches no item rows because nothing keys on it.
struct Workspace: Codable, Equatable, FetchableRecord, PersistableRecord {
    let id: String
    var name: String
    var personaName: String
    var spendShow: Bool          // show the title-bar spend pill
    var spendStaleHours: Int     // hours before the pill flags stale; 0 = never
    var spendState: SpendState?  // latest captured state (JSON column); nil until first capture
    var priorityShow: Bool          // show the title-bar priority pill
    var priorityStaleHours: Int     // hours before the pill flags stale; 0 = never
    var priorityState: PriorityState?  // latest captured snapshot (JSON column); nil until first capture
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "workspace"

    /// The persona the embedded agent loads when no explicit choice is stored.
    static let defaultPersonaName = "assist-ant-work"

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case personaName = "persona_name"
        case spendShow = "spend_show"
        case spendStaleHours = "spend_stale_hours"
        case spendState = "spend_state"
        case priorityShow = "priority_show"
        case priorityStaleHours = "priority_stale_hours"
        case priorityState = "priority_state"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// A fresh workspace with a random opaque id, the default name, and the
    /// default persona.
    static func make(now: Date = Date()) -> Workspace {
        Workspace(
            id: UUID().uuidString.lowercased(),
            name: defaultName(),
            personaName: defaultPersonaName,
            spendShow: false,
            spendStaleHours: 24,
            spendState: nil,
            priorityShow: false,
            priorityStaleHours: 24,
            priorityState: nil,
            createdAt: now,
            updatedAt: now)
    }

    /// The default display name for a newly seated workspace: the device's
    /// host name (so a work laptop names itself), falling back to a generic
    /// label when the host name is unavailable.
    static func defaultName() -> String {
        let host = Host.current().localizedName
        return (host?.isEmpty == false) ? host! : "My Workspace"
    }
}
