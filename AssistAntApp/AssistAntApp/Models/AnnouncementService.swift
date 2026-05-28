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
    private var micObserver: AnyCancellable?
    private var lastFiredMinute: Date?

    /// Set when a boundary that would otherwise have fired was
    /// suppressed *specifically* because the mic was in use. When the
    /// mic later frees (and nothing else is muting), this triggers a
    /// one-shot spoken catch-up of the current time so the user isn't
    /// left unaware of the time after a call. In-memory only — a
    /// pending catch-up does not survive relaunch. A single flag, not
    /// a queue: any number of mic-suppressed boundaries yields at most
    /// one catch-up.
    private var pendingMicCatchUp = false

    private init() {
        clockObserver = ClockService.shared.$currentTime
            .sink { [weak self] now in
                self?.evaluate(at: now)
            }

        // React to mic engaging/freeing. ON is immediate (cancel any
        // in-flight announcement so it can't leak into a call); OFF is
        // already debounced by MicActivityService, and is where the
        // catch-up fires.
        micObserver = MicActivityService.shared.$isMicInUse
            .removeDuplicates()
            .sink { [weak self] inUse in
                if inUse {
                    self?.handleMicEngaged()
                } else {
                    self?.handleMicReleased()
                }
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
        schedule: WeeklySchedule,
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

        // Schedule gate: is today's slot active right now? The schedule
        // is passed in (it now lives on AppSettings, shared with the
        // desk timer) rather than reached through `settings`.
        let timeOfDay = TimeOfDay(hour: hour, minute: minute)
        guard schedule.isActive(at: timeOfDay, weekday: weekday)
        else { return nil }

        // Mute override: explicit user-set silence window. Applied
        // last so the schedule/interval reasoning is independent of
        // mute state — mute just suppresses an otherwise-firing
        // boundary. Gates both sound and speech outputs atomically
        // because both dispatches downstream of this point are
        // gated on the boundary return.
        if let muteUntil = settings.muteUntil, now < muteUntil {
            return nil
        }

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

        guard let boundary = Self.shouldFire(
            at: now, settings: settings, schedule: appSettings.schedule
        ) else { return }

        // Early-out if neither output is on. Still mark the minute as
        // fired so subsequent ticks within the same minute don't
        // reconsider.
        guard settings.playSound || settings.speakTime else {
            lastFiredMinute = minuteKey
            return
        }

        // Mic gate: if the mic is live and "mute while mic in use" is
        // on, suppress this boundary and remember it so a spoken
        // catch-up can fire when the mic frees. This is the only
        // suppression path that sets the catch-up flag — timed mute
        // and out-of-window are handled inside shouldFire and never
        // reach here, so a catch-up only ever stands in for an
        // announcement the mic specifically swallowed.
        if appSettings.muteWhileMicInUse,
           MicActivityService.shared.isMicInUse {
            pendingMicCatchUp = true
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

        // A normal announcement just fired, so there's nothing for a
        // catch-up to stand in for.
        pendingMicCatchUp = false
        lastFiredMinute = minuteKey
    }

    /// Mic just went live. Abort any announcement already in flight so
    /// its tail can't leak into the call. Gated on the toggle so this
    /// is a no-op when the user hasn't opted into mic-muting.
    private func handleMicEngaged() {
        guard SettingsManager.shared.settings.muteWhileMicInUse
        else { return }
        SoundSequencer.shared.stop()
        SpeechAnnouncer.shared.stop()
    }

    /// Mic freed (after MicActivityService's release cooldown). If a
    /// boundary was swallowed by the mic while it was live, speak the
    /// *current* time once as a catch-up — speech only, and regardless
    /// of whether we're still inside the schedule window. A still-
    /// active timed mute, a disabled master, the toggle being off, or
    /// speech being off all cancel the catch-up (the flag is dropped
    /// either way).
    private func handleMicReleased() {
        guard pendingMicCatchUp else { return }
        pendingMicCatchUp = false

        let appSettings = SettingsManager.shared.settings
        let settings = appSettings.announcement
        guard settings.enabled,
              appSettings.muteWhileMicInUse,
              settings.speakTime
        else { return }

        // Timed mute still wins — if the user is muted until a later
        // time, honor that silence rather than the catch-up.
        let now = Date()
        if let until = settings.muteUntil, now < until { return }

        SpeechAnnouncer.shared.speak(
            time: now,
            format: appSettings.timeFormat,
            voiceIdentifier: settings.voiceIdentifier
        )
    }
}
