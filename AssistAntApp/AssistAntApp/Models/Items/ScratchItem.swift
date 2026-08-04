import Foundation

/// Builds a scratch `Item` from a note's text — the shape both the Scratch
/// composer and the `scratch.add` socket request write. Pure and
/// dependency-free, mirroring `CapturedItem`, so the smoke tool can verify the
/// disposition without a model, a socket, or an AppDelegate.
///
/// It exists because the two writers cannot share a code path any other way:
/// `ScratchModel` is `@MainActor`, and the socket handler answers on the
/// listener queue — hopping to main there would forfeit the synchronous id ack
/// that makes `scratch.add` request/reply in the first place. Hand-rolling the
/// row in the handler instead would give a note two definitions that drift.
///
/// Disposition: body-only. The text lands in `body`, and `title` is derived from
/// it (`title` is NOT NULL and the shared Trash renders rows by title). The
/// payload carries only the list, when the caller named one — the composer never
/// does, so a note typed into the pane lands unfiled and is grouped from the
/// keyboard afterwards. Every actionable column — schedule, icebox, resolution,
/// position — stays nil: a note is not work until it is converted into some.
enum ScratchItem {
    /// Returns nil for blank text. The composer's submit keystroke is easy to
    /// hit twice and an empty `--text` is easy to pass, and neither should store
    /// an empty note. A blank `listName` parks the note unfiled for the same
    /// reason, so `--list ''` cannot store a list nothing can display.
    static func make(
        text: String, listName: String? = nil,
        workspaceID: String, now: Date = Date()
    ) -> Item? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let list = listName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Item(
            id: UUIDv7.generate(),
            workspaceID: workspaceID,
            type: ItemType.scratch.rawValue,
            title: ScratchTitle.derive(from: trimmed),
            body: trimmed,
            source: "manual",
            externalID: nil,
            typeData: .scratch(ScratchData(
                listName: (list?.isEmpty == false) ? list : nil)),
            iceboxedAt: nil,
            deletedAt: nil,
            scheduledOn: nil,
            resolvedAt: nil,
            position: nil,
            createdAt: now,
            updatedAt: now,
            serverUpdatedAt: nil,
            pending: false
        )
    }
}
