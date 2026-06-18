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
        let kind: String            // todo / reminder / explore / calendar
        let title: String
        let preview: String?
        let scheduledOn: String?    // "YYYY-MM-DD", nil when unscheduled
        let resolvedToday: Bool
        let source: String          // manual / linear / gcal
        let externalID: String?     // e.g. FLEX-3304 — Linear cross-ref
        let externalURL: String?    // actionable link, or a calendar join link
        let listName: String?
        /// Manual drag-reorder rank within the list (lower = higher in the
        /// list). nil when unranked. Comparable within a `listName`, not across.
        let position: Double?
        /// Calendar-only timing (nil — and omitted from JSON — for actionable
        /// rows). `startAt`/`endAt` are ISO-8601 instants; the rest of the event
        /// context (calendar name, RSVP, location, attendees) rides in `preview`,
        /// the flattened body the calendar sync composed.
        let startAt: String?
        let endAt: String?
        let allDay: Bool?

        private static let isoInstant = ISO8601DateFormatter()

        /// Map any item — actionable or calendar — to a row.
        init(_ item: Item, today: CivilDate) {
            id = item.id
            kind = item.typeData.kind
            title = item.title
            preview = item.bodyPlainPreview
            scheduledOn = item.scheduledOn?.iso
            resolvedToday = item.resolvedAt.map { CivilDate($0) == today } ?? false
            source = item.source
            externalID = item.externalID
            position = item.position
            if case .calendar(let cal) = item.typeData {
                externalURL = cal.externalURL
                listName = nil
                startAt = cal.startAt.map(Self.isoInstant.string(from:))
                endAt = cal.endAt.map(Self.isoInstant.string(from:))
                allDay = cal.allDay
            } else {
                externalURL = item.actionableExternalURL
                listName = item.actionableListName
                startAt = nil
                endAt = nil
                allDay = nil
            }
        }
    }

    /// The previously captured priority snapshot, surfaced so the progress skill
    /// can note movement since last time. `capturedAt` is ISO-8601; null until
    /// the first `priority set`.
    struct PriorityRef: Codable, Equatable {
        let capturedAt: String
        let body: String
    }

    let today: [Row]
    let upcoming: [Row]
    let icebox: IceboxSummary
    let generatedOn: String         // "YYYY-MM-DD"
    let lastPriority: PriorityRef?

    /// Assemble from the store: the Today list (actionables plus today's calendar
    /// events), the lookahead (tomorrow → end of next week, Monday-aligned), and
    /// the icebox summary. Calendar events carry their start/end times; the rest
    /// of the event context (calendar name, RSVP, attendees) rides in `preview`.
    static func current(
        store: ItemStore, asOf today: CivilDate = .today,
        priority: PriorityState? = nil
    ) throws -> BriefingSnapshot {
        let endOfNextWeek = today.mondayOfWeek().adding(days: 13)
        // The sidebar request excludes calendar items, so fetch today's events
        // separately and append them; the lookahead never filtered by type, so
        // its calendar events simply stop being dropped.
        let todayActionable = try store.fetchTodaySidebar(asOf: today)
            .map { Row($0, today: today) }
        let todayCalendar = try store.fetchActive(
            type: .calendar, from: today, to: today
        ).map { Row($0, today: today) }
        let todayRows = todayActionable + todayCalendar
        let upcomingRows = try store.fetchActive(
            type: nil, from: today.adding(days: 1), to: endOfNextWeek
        ).map { Row($0, today: today) }
        let icebox = try store.iceboxSummary(asOf: today)
        let lastPriority = priority.map {
            PriorityRef(
                capturedAt: ISO8601DateFormatter().string(from: $0.capturedAt),
                body: $0.body)
        }
        return BriefingSnapshot(
            today: todayRows, upcoming: upcomingRows,
            icebox: icebox, generatedOn: today.iso, lastPriority: lastPriority)
    }

    /// Encode to one compact JSON line for the socket reply. On any failure,
    /// returns a small JSON error object so the caller never times out.
    static func replyData(
        store: ItemStore = GRDBItemStore.shared, asOf today: CivilDate = .today
    ) -> Data {
        do {
            let priority = try? WorkspaceStore.shared.current().priorityState
            return try JSONEncoder().encode(
                current(store: store, asOf: today, priority: priority))
        } catch {
            let payload = ["error": String(describing: error)]
            return (try? JSONEncoder().encode(payload))
                ?? Data(#"{"error":"unknown"}"#.utf8)
        }
    }
}
