import Foundation
import AppKit
import Combine

/// Plays an announcement sound when the user's schedule + interval align
/// with the current minute. Singleton, subscribes to
/// `ClockService.$currentTime` and reads `SettingsManager.shared.settings`
/// at each tick.
///
/// Phase 1: plays a sound, repeated 1/2/4 times based on the boundary
/// (quarter/half/top). Phase 2 will add speech alongside; the same
/// shouldFire / boundary logic gates both outputs.
final class AnnouncementService {
    static let shared = AnnouncementService()

    private var clockObserver: AnyCancellable?
    private var lastFiredMinute: Date?

    private init() {
        clockObserver = ClockService.shared.$currentTime
            .sink { [weak self] now in
                self?.evaluate(at: now)
            }
    }

    /// Pure decision: should an announcement fire at `now` given
    /// `settings`? Returns the boundary type so the caller knows how
    /// many chimes to play. Side-effect-free so it can be exercised
    /// without audio.
    static func shouldFire(
        at now: Date,
        settings: AnnouncementSettings,
        calendar: Calendar = .current
    ) -> AnnouncementBoundary? {
        guard settings.enabled, settings.playSound else { return nil }

        let components = calendar.dateComponents(
            [.weekday, .hour, .minute], from: now
        )
        guard
            let weekdayInt = components.weekday,
            let weekday = Weekday(rawValue: weekdayInt),
            let hour = components.hour,
            let minute = components.minute
        else { return nil }

        // Interval gate: does the user want any chime at this minute?
        guard settings.interval.fireMinutes.contains(minute) else {
            return nil
        }

        // Schedule gate: is today's slot active right now?
        let timeOfDay = TimeOfDay(hour: hour, minute: minute)
        guard settings.schedule.isActive(at: timeOfDay, weekday: weekday)
        else { return nil }

        // Boundary type: how many chimes to play at this minute?
        return AnnouncementBoundary.from(minute: minute)
    }

    private func evaluate(at now: Date) {
        let settings = SettingsManager.shared.settings.announcement

        // Debounce: ClockService can theoretically publish the same minute
        // twice (sleep/wake realign). Skip if we already fired for this
        // minute.
        let minuteKey = Calendar.current.dateInterval(
            of: .minute, for: now
        )?.start
        if let last = lastFiredMinute,
           let key = minuteKey,
           last == key {
            return
        }

        if let boundary = Self.shouldFire(at: now, settings: settings) {
            SoundSequencer.shared.play(
                settings.sound,
                count: boundary.soundCount
            )
            lastFiredMinute = minuteKey
        }
    }
}
