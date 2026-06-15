import Foundation

/// The store-side payload the assist-ant persona reads at startup, in reply to a
/// `briefing.query` socket request. Three slices: the literal Today list, a
/// through-end-of-next-week lookahead, and the icebox trend summary. Compact and
/// agent-facing — only the fields the briefing needs, including the Linear
/// cross-reference (`source` + `externalID`/`externalURL`). No SwiftUI/AppKit,
/// so it lives in the items model and is exercised by ItemsSmoke.
struct BriefingSnapshot: Codable, Equatable {
    struct Row: Codable, Equatable {
        let id: String
        let kind: String            // todo / reminder / explore
        let title: String
        let preview: String?
        let scheduledOn: String?    // "YYYY-MM-DD", nil when unscheduled
        let resolvedToday: Bool
        let source: String          // manual / linear / gcal
        let externalID: String?     // e.g. FLEX-3304 — Linear cross-ref
        let externalURL: String?
        let listName: String?
        /// Manual drag-reorder rank within the list (lower = higher in the
        /// list). nil when unranked. Comparable within a `listName`, not across.
        let position: Double?

        /// Map an actionable item to a row; calendar items return nil — the
        /// briefing's calendar comes from the live MCP pull, not the store.
        init?(_ item: Item, today: CivilDate) {
            let kind = item.typeData.kind
            guard kind != ItemType.calendar.rawValue else { return nil }
            id = item.id
            self.kind = kind
            title = item.title
            preview = item.bodyPlainPreview
            scheduledOn = item.scheduledOn?.iso
            resolvedToday = item.resolvedAt.map { CivilDate($0) == today } ?? false
            source = item.source
            externalID = item.externalID
            externalURL = item.actionableExternalURL
            listName = item.actionableListName
            position = item.position
        }
    }

    let today: [Row]
    let upcoming: [Row]
    let icebox: IceboxSummary
    let generatedOn: String         // "YYYY-MM-DD"

    /// Assemble from the store: the Today list, the lookahead (tomorrow → end of
    /// next week, Monday-aligned), and the icebox summary. Calendar items are
    /// dropped from both lists (the briefing's calendar is the live MCP pull).
    static func current(
        store: ItemStore, asOf today: CivilDate = .today
    ) throws -> BriefingSnapshot {
        let endOfNextWeek = today.mondayOfWeek().adding(days: 13)
        let todayRows = try store.fetchTodaySidebar(asOf: today)
            .compactMap { Row($0, today: today) }
        let upcomingRows = try store.fetchActive(
            type: nil, from: today.adding(days: 1), to: endOfNextWeek
        ).compactMap { Row($0, today: today) }
        let icebox = try store.iceboxSummary(asOf: today)
        return BriefingSnapshot(
            today: todayRows, upcoming: upcomingRows,
            icebox: icebox, generatedOn: today.iso)
    }

    /// Encode to one compact JSON line for the socket reply. On any failure,
    /// returns a small JSON error object so the caller never times out.
    static func replyData(
        store: ItemStore = GRDBItemStore.shared, asOf today: CivilDate = .today
    ) -> Data {
        do {
            return try JSONEncoder().encode(current(store: store, asOf: today))
        } catch {
            let payload = ["error": String(describing: error)]
            return (try? JSONEncoder().encode(payload))
                ?? Data(#"{"error":"unknown"}"#.utf8)
        }
    }
}
