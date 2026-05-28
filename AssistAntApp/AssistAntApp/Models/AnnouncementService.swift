import Foundation
import AppKit
import Combine

/// Plays an announcement when the user's schedule + interval align with
/// the current minute. Singleton, subscribes to
/// `ClockService.$currentTime` and reads
/// `SettingsManager.shared.settings` at each tick.
///
/// Two outputs — sound chimes and spoken time — are dispatched
/// independently based on the per-output toggles (`playSound`,
/// `speakTime`). Either, both, or neither can be on. When both are
/// on, the chime sequence plays first and speech follows at the
/// inter-chime cadence (1 second after the last chime starts) so the
/// announcement reads as a single rhythmic event.
final class AnnouncementService {
    static let shared = AnnouncementService()

    /// Inter-chime delay, kept in sync with `SoundSequencer`'s. Speech
    /// scheduling reuses this so speech lands one beat after the last
    /// chime starts — for 4 chimes (top of hour) at 0s/1s/2s/3s,
    /// speech begins at 4s.
    private static let chimeBeat: TimeInterval = 1.0

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
    /// many chimes to play (and how long to wait before speaking).
    /// Side-effect-free.
    ///
    /// This no longer checks `playSound` — the gate is now purely
    /// about whether *any* announcement should fire at this minute
    /// (master enable + interval + schedule). The dispatcher in
    /// `evaluate` decides which outputs (sound, speech, both) to
    /// fire based on the per-output toggles.
    static func shouldFire(
        at now: Date,
        settings: AnnouncementSettings,
        calendar: Calendar = .current
    ) -> AnnouncementBoundary? {
        guard settings.enabled else { return nil }

        let components = calendar.dateComponents(
            [.weekday, .hour, .minute], from: now
        )
        guard
            let weekdayInt = components.weekday,
            let weekday = Weekday(rawValue: weekdayInt),
            let hour = components.hour,
            let minute = components.minute
        else { return nil }

        // Interval gate: does the user want any announcement at this minute?
        guard settings.interval.fireMinutes.contains(minute) else {
            return nil
        }

        // Schedule gate: is today's slot active right now?
        let timeOfDay = TimeOfDay(hour: hour, minute: minute)
        guard settings.schedule.isActive(at: timeOfDay, weekday: weekday)
        else { return nil }

        // Boundary type: how many chimes to play, and the speech delay
        // when sound is also on.
        return AnnouncementBoundary.from(minute: minute)
    }

    private func evaluate(at now: Date) {
        let appSettings = SettingsManager.shared.settings
        let settings = appSettings.announcement

        // Debounce: ClockService can theoretically publish the same
        // minute twice (sleep/wake realign). Skip if we already fired
        // for this minute.
        let minuteKey = Calendar.current.dateInterval(
            of: .minute, for: now
        )?.start
        if let last = lastFiredMinute,
           let key = minuteKey,
           last == key {
            return
        }

        guard let boundary = Self.shouldFire(at: now, settings: settings)
        else { return }

        // Early-out if neither output is on. Still mark the minute as
        // fired so subsequent ticks within the same minute don't
        // reconsider.
        guard settings.playSound || settings.speakTime else {
            lastFiredMinute = minuteKey
            return
        }

        // Sound dispatch — chime count derived from the boundary type
        // (4 / 2 / 1 for top / half / quarter).
        if settings.playSound {
            SoundSequencer.shared.play(
                settings.sound,
                count: boundary.soundCount
            )
        }

        // Speech dispatch. When sound is also on, delay speech by
        // `chimeCount * chimeBeat` so it lands one beat after the
        // last chime starts (matching the inter-chime rhythm). When
        // sound is off, speak immediately at the boundary minute.
        if settings.speakTime {
            let delay: TimeInterval = settings.playSound
                ? Double(boundary.soundCount) * Self.chimeBeat
                : 0
            let format = appSettings.timeFormat
            let voiceId = settings.voiceIdentifier

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                SpeechAnnouncer.shared.speak(
                    time: now,
                    format: format,
                    voiceIdentifier: voiceId
                )
            }
        }

        lastFiredMinute = minuteKey
    }
}
