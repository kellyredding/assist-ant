import Combine
import Foundation

/// Fires audible announcements for upcoming calendar items. Singleton:
/// holds the live active-calendar feed from the store and re-evaluates on
/// every minute tick from `ClockService`. Output goes through the shared
/// `AudioAnnouncementCoordinator` at `.calendar` priority, so it serializes
/// with time/desk audio and never overlaps.
///
/// Gating is delegated to `AppSettings.audioGateOpen` — the same speaker-icon
/// gate the time chime uses — plus the feature's own `enabled` toggle. A
/// boundary that a *temporary* silence swallows is remembered per meeting and
/// replayed when `TemporaryMuteMonitor` reports the silence lifted, with the
/// lead recomputed for that moment; a meeting that has since started is
/// dropped rather than announced late, since the likeliest reason for the
/// silence is that the user went to it.
///
/// The decisions themselves live in `CalendarAnnouncementDecisions`, apart
/// from the Combine wiring here so they can be exercised directly.
@MainActor
final class CalendarAnnouncementService {
    static let shared = CalendarAnnouncementService()

    private var clockObserver: AnyCancellable?
    private var itemsObserver: AnyCancellable?
    private var muteObserver: AnyCancellable?

    /// Latest active calendar items from the store. Refreshed reactively;
    /// read on each clock tick.
    private var activeCalendarItems: [Item] = []

    /// In-memory dedup of already-decided (itemID, minutesBefore) boundaries,
    /// so a boundary is acted on at most once. Pruned to currently-active
    /// items each tick so it can't grow without bound. Not persisted — a
    /// relaunch starts clean (and past boundaries won't re-match anyway).
    private var firedKeys: Set<String> = []

    /// Meetings whose announcement a temporary silence swallowed, keyed by
    /// item so a meeting whose 10- and 5-minute leads were both missed still
    /// yields one catch-up. In-memory only, matching the time catch-up: a
    /// pending replay does not survive relaunch.
    private var missedItemIDs: Set<String> = []

    private init() {
        itemsObserver = GRDBItemStore.shared.observeActive(type: .calendar)
            .replaceError(with: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in self?.activeCalendarItems = items }

        clockObserver = ClockService.shared.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] now in self?.evaluate(at: now) }

        muteObserver = TemporaryMuteMonitor.shared.didLift
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handleSilenceLifted() }
    }

    private func evaluate(at now: Date) {
        let app = SettingsManager.shared.settings
        let cal = app.calendarAnnouncement

        guard cal.enabled else { return }
        guard cal.playSound || cal.speakEvent else { return }

        // Prune both sets to items that are still active so neither grows
        // without bound and a deleted meeting stops being a catch-up
        // candidate.
        let activeIDs = Set(activeCalendarItems.map(\.id))
        firedKeys = firedKeys.filter { key in
            activeIDs.contains(String(key.prefix(while: { $0 != ":" })))
        }
        missedItemIDs = missedItemIDs.filter { activeIDs.contains($0) }

        // The gate is consulted per boundary rather than up front: a boundary
        // silenced right now still has to be recorded, and that cannot happen
        // from an early return above the due computation.
        let micInUse = MicActivityService.shared.isMicInUse
        let gateOpen = app.audioGateOpen(at: now, micInUse: micInUse)
        let temporary = app.isTemporarilySilenced(micInUse: micInUse)

        let due = CalendarAnnouncementDecisions.due(
            items: activeCalendarItems, now: now, settings: cal)
        for boundary in due {
            let key = "\(boundary.itemID):\(boundary.minutesBefore)"
            guard !firedKeys.contains(key) else { continue }
            firedKeys.insert(key)

            if gateOpen {
                submit(boundary, settings: cal)
            } else if temporary {
                missedItemIDs.insert(boundary.itemID)
            }
            // Otherwise the silence is the hours window or the master switch —
            // standing preferences, not interruptions, so nothing is owed.
        }
    }

    /// Temporary silence ended: announce every missed meeting that is still
    /// ahead, soonest first, each with a lead recomputed for this moment.
    /// Meetings that have since started are dropped silently.
    private func handleSilenceLifted() {
        guard !missedItemIDs.isEmpty else { return }
        let missed = missedItemIDs
        missedItemIDs.removeAll()

        let app = SettingsManager.shared.settings
        let cal = app.calendarAnnouncement
        let now = Date()
        guard cal.enabled, cal.playSound || cal.speakEvent,
              app.audioGateOpen(at: now, micInUse: false)
        else { return }

        for boundary in CalendarAnnouncementDecisions.catchUps(
            items: activeCalendarItems, missedItemIDs: missed, now: now
        ) {
            submit(boundary, settings: cal)
        }
    }

    /// Build and hand off one announcement. Shared by the live path and the
    /// catch-up so the two cannot drift in sound, voice, or priority.
    private func submit(
        _ boundary: CalendarAnnouncementDecisions.DueBoundary,
        settings cal: CalendarAnnouncementSettings
    ) {
        AudioAnnouncementCoordinator.shared.submit(.init(
            sound: cal.playSound ? cal.sound : nil,
            soundCount: cal.playSound ? 1 : 0,
            speech: cal.speakEvent
                ? SpeechAnnouncer.eventPhrase(
                    title: boundary.title,
                    minutesBefore: boundary.minutesBefore)
                : nil,
            voiceIdentifier: cal.voiceIdentifier,
            priority: .calendar
        ))
    }
}
