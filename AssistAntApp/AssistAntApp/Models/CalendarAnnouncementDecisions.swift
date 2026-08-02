import Foundation

/// The side-effect-free decisions behind upcoming-event announcements, kept
/// apart from the Combine-driven service so they can be exercised directly.
enum CalendarAnnouncementDecisions {

    /// One boundary that is due to announce.
    struct DueBoundary: Equatable {
        let itemID: String
        let title: String
        let minutesBefore: Int
    }

    /// Which (item, lead) boundaries are due at `now`? All-day and undated
    /// items are skipped explicitly (defense in depth — the ingest path
    /// already excludes them). Past events never match.
    static func due(
        items: [Item],
        now: Date,
        settings: CalendarAnnouncementSettings
    ) -> [DueBoundary] {
        var leads = settings.leadMinutes
        if settings.announceStart { leads.insert(0) }
        guard !leads.isEmpty else { return [] }

        var due: [DueBoundary] = []
        for item in items {
            guard let minutesUntil = minutesUntilStart(of: item, now: now)
            else { continue }
            guard minutesUntil >= 0, leads.contains(minutesUntil) else {
                continue
            }
            due.append(DueBoundary(
                itemID: item.id, title: item.title,
                minutesBefore: minutesUntil))
        }
        return due
    }

    /// Which missed meetings still deserve an announcement at `now`, soonest
    /// first?
    ///
    /// A meeting whose start has passed yields nothing. The likeliest reason
    /// the silence existed is that the user went to the meeting, which makes
    /// the reminder redundant rather than useful.
    ///
    /// A meeting still ahead is announced with a lead recomputed from `now`,
    /// never the lead that was originally swallowed — "in two minutes" is the
    /// statement that is true when it is finally spoken. At most one entry per
    /// meeting however many of its leads were missed, since the recomputed
    /// lead is the same answer for all of them.
    ///
    /// Ties break on title so a burst is ordered deterministically rather than
    /// by whatever order the store happened to return.
    static func catchUps(
        items: [Item],
        missedItemIDs: Set<String>,
        now: Date
    ) -> [DueBoundary] {
        var out: [DueBoundary] = []
        for item in items where missedItemIDs.contains(item.id) {
            guard let minutesUntil = minutesUntilStart(of: item, now: now),
                  minutesUntil >= 0
            else { continue }
            out.append(DueBoundary(
                itemID: item.id, title: item.title,
                minutesBefore: minutesUntil))
        }
        return out.sorted {
            ($0.minutesBefore, $0.title) < ($1.minutesBefore, $1.title)
        }
    }

    /// Whole minutes until a timed calendar item starts, or nil when the item
    /// carries no start to count toward. Rounded so a sub-minute start offset
    /// still lands on a whole-minute lead.
    private static func minutesUntilStart(of item: Item, now: Date) -> Int? {
        guard case .calendar(let data) = item.typeData else { return nil }
        guard !data.allDay, let start = data.startAt else { return nil }
        return Int((start.timeIntervalSince(now) / 60).rounded())
    }
}
