import Foundation

/// Builds a manual actionable `Item` from a captured-item payload (the
/// `actionable_item.create` fields). Pure and dependency-free so the smoke test
/// can verify the capture disposition without the socket or AppDelegate.
///
/// Disposition: `source = "manual"`, `externalID = nil` (manual items carry no
/// identity key and coexist freely), and `scheduledOn` set only when the prompt
/// named a day. By default the item is non-iceboxed and unscheduled — so it
/// lands on Today and accumulates there until rescheduled or iceboxed. Passing
/// `icebox: true` stamps `iceboxedAt = now` instead, routing it straight to the
/// Icebox (the icebox flag supersedes any schedule for display).
enum CapturedItem {
    /// Returns nil when `kind` isn't an actionable kind or `title` is blank.
    static func make(
        kind: String?,
        title: String?,
        body: String?,
        scheduledOnISO: String?,
        externalURL: String?,
        icebox: Bool = false,
        workspaceID: String,
        now: Date = Date()
    ) -> Item? {
        guard let kind, let type = ItemType(rawValue: kind),
              [.todo, .reminder, .explore].contains(type) else { return nil }

        let trimmedTitle = (title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }

        let data = ActionableData(listName: nil, externalURL: externalURL)
        let typeData: ItemTypeData
        switch type {
        case .todo: typeData = .todo(data)
        case .reminder: typeData = .reminder(data)
        case .explore: typeData = .explore(data)
        default: return nil   // calendar / unknown excluded by the guard above
        }

        let trimmedBody = body?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Item(
            id: UUIDv7.generate(),
            workspaceID: workspaceID,
            type: type.rawValue,
            title: trimmedTitle,
            body: (trimmedBody?.isEmpty == false) ? trimmedBody : nil,
            source: "manual",
            externalID: nil,
            typeData: typeData,
            iceboxedAt: icebox ? now : nil,
            deletedAt: nil,
            scheduledOn: scheduledOnISO.flatMap(CivilDate.init(iso:)),
            createdAt: now,
            updatedAt: now,
            serverUpdatedAt: nil,
            pending: true
        )
    }
}
