import Combine
import Foundation

/// Fires audible announcements for upcoming calendar items. Singleton:
/// holds the live active-calendar feed from the store and re-evaluates on
/// every minute tick from `ClockService`. Output goes through the shared
/// `AudioAnnouncementCoordinator` at `.calendar` priority, so it serializes
/// with time/desk audio and never overlaps.
///
/// Gating is delegated entirely to `AppSettings.audioGateOpen` — the same
/// speaker-icon gate the time chime uses — plus the feature's own `enabled`
/// toggle. There is intentionally no mic-release "catch-up": a missed event
/// announcement is stale, not worth replaying after a call.
@MainActor
final class CalendarAnnouncementService {
    static let shared = CalendarAnnouncementService()

    private var clockObserver: AnyCancellable?
    private var itemsObserver: AnyCancellable?

    /// Latest active calendar items from the store. Refreshed reactively;
    /// read on each clock tick.
    private var activeCalendarItems: [Item] = []

    /// In-memory dedup of already-fired (itemID, minutesBefore) boundaries,
    /// so a boundary fires at most once. Pruned to currently-active items
    /// each tick so it can't grow without bound. Not persisted — a relaunch
    /// starts clean (and past boundaries won't re-match anyway).
    private var firedKeys: Set<String> = []

    private init() {
        itemsObserver = GRDBItemStore.shared.observeActive(type: .calendar)
            .replaceError(with: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in self?.activeCalendarItems = items }

        clockObserver = ClockService.shared.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] now in self?.evaluate(at: now) }
    }

    /// One boundary that is due to announce right now.
    struct DueBoundary: Equatable {
        let itemID: String
        let title: String
        let minutesBefore: Int
    }

    /// Pure decision: which (item, lead) boundaries are due at `now`?
    /// Side-effect-free. All-day and undated items are skipped explicitly
    /// (defense in depth — the ingest path already excludes them). Past
    /// events (negative minutesUntil) never match.
    static func dueAnnouncements(
        items: [Item],
        now: Date,
        settings: CalendarAnnouncementSettings
    ) -> [DueBoundary] {
        var leads = settings.leadMinutes
        if settings.announceStart { leads.insert(0) }
        guard !leads.isEmpty else { return [] }

        var due: [DueBoundary] = []
        for item in items {
            guard case .calendar(let data) = item.typeData else { continue }
            // Explicit all-day / undated skip.
            guard !data.allDay, let start = data.startAt else { continue }
            // Round to the nearest minute so a sub-minute start offset
            // still lands on a whole-minute lead.
            let minutesUntil = Int((start.timeIntervalSince(now) / 60).rounded())
            guard minutesUntil >= 0, leads.contains(minutesUntil) else { continue }
            due.append(DueBoundary(
                itemID: item.id, title: item.title, minutesBefore: minutesUntil
            ))
        }
        return due
    }

    private func evaluate(at now: Date) {
        let app = SettingsManager.shared.settings
        let cal = app.calendarAnnouncement

        guard cal.enabled else { return }
        guard cal.playSound || cal.speakEvent else { return }
        guard app.audioGateOpen(
            at: now, micInUse: MicActivityService.shared.isMicInUse
        ) else { return }

        // Prune dedup keys for items no longer active so the set stays small.
        let activeIDs = Set(activeCalendarItems.map(\.id))
        firedKeys = firedKeys.filter { key in
            activeIDs.contains(String(key.prefix(while: { $0 != ":" })))
        }

        let due = Self.dueAnnouncements(
            items: activeCalendarItems, now: now, settings: cal
        )
        for boundary in due {
            let key = "\(boundary.itemID):\(boundary.minutesBefore)"
            guard !firedKeys.contains(key) else { continue }
            firedKeys.insert(key)

            let job = AudioAnnouncementCoordinator.Job(
                sound: cal.playSound ? cal.sound : nil,
                soundCount: cal.playSound ? 1 : 0,
                speech: cal.speakEvent
                    ? SpeechAnnouncer.eventPhrase(
                        title: boundary.title, minutesBefore: boundary.minutesBefore
                    )
                    : nil,
                voiceIdentifier: cal.voiceIdentifier,
                priority: .calendar
            )
            AudioAnnouncementCoordinator.shared.submit(job)
        }
    }
}
