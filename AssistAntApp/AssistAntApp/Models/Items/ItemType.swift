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
    case scratch
}

extension ItemType {
    /// The kinds that behave as actionable work — schedule, accumulate,
    /// resolve. `calendar` is read-only and `scratch` is an unshaped note, so
    /// neither belongs here.
    ///
    /// The single source for the `type IN (...)` predicates that gate Today,
    /// the Today sidebar, the icebox summary, reclassify, and the CLI's active
    /// list. Those were seven hand-written copies of one list; a fifth kind is
    /// what turned that repetition from harmless into a hazard.
    static let actionableCases: [ItemType] = [.todo, .reminder, .explore]

    /// The actionable kinds as a SQL list literal, for the store's
    /// `filter(sql:)` predicates.
    ///
    /// Interpolated rather than bound as arguments: every value derives from
    /// this enum at compile time and no user input reaches it, while an `IN`
    /// clause with bound arguments needs generated placeholders that then have
    /// to be merged with each query's own arguments — fiddlier, for no safety
    /// this does not already have.
    static let actionableSQLList: String = actionableCases
        .map { "'\($0.rawValue)'" }
        .joined(separator: ", ")
}
