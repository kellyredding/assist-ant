import Foundation
import Combine

/// Decides when a time announcement should fire and submits it to the
/// shared `AudioAnnouncementCoordinator`. Singleton, subscribes to
/// `ClockService.$currentTime` and reads `SettingsManager.shared.settings`
/// at each tick.
///
/// It no longer touches the audio players directly — it builds a
/// coordinator `Job` (sound and/or speech, priority `.time`) and submits
/// it, so time announcements and desk nudges share one serializer (time
/// first, never overlapping) and one gate. Mic-engage cancellation is
/// owned by the coordinator; this service only handles the mic-release
/// catch-up.
final class AnnouncementService {
    static let shared = AnnouncementService()

    private var clockObserver: AnyCancellable?
    private var micObserver: AnyCancellable?
    private var lastFiredMinute: Date?

    /// Set when a boundary that would otherwise have fired was
    /// suppressed *specifically* because the mic was in use. When the
    /// mic later frees (and the gate is otherwise open), this triggers a
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

        // The coordinator owns cancel-on-mic-engage, so this service only
        // reacts to the mic *freeing* (already debounced by
        // MicActivityService), where the spoken catch-up fires.
        micObserver = MicActivityService.shared.$isMicInUse
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in self?.handleMicReleased() }
    }

    /// Pure decision: should an announcement fire at `now`? Returns the
    /// boundary type so the caller knows how many chimes to play.
    /// Side-effect-free.
    ///
    /// Checks master enable + interval + schedule, then the global manual
    /// mute (`isMuted`, passed in). It does not check `playSound` — that
    /// only decides which outputs the submitted job carries.
    static func shouldFire(
        at now: Date,
        settings: AnnouncementSettings,
        schedule: WeeklySchedule,
        isMuted: Bool,
        isAway: Bool,
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
        guard schedule.isActive(at: timeOfDay, weekday: weekday)
        else { return nil }

        // Away override: stepping away from the desk silences time
        // announcements too, superseding the manual mute and the
        // schedule — the same way mic-in-use does.
        if isAway {
            return nil
        }

        // Mute override: the global manual mute. Applied last so the
        // schedule/interval reasoning is independent of mute state.
        if isMuted {
            return nil
        }

        return AnnouncementBoundary.from(minute: minute)
    }

    private func evaluate(at now: Date) {
        let appSettings = SettingsManager.shared.settings
        let settings = appSettings.announcement

        // Master kill switch: announcements globally disabled — no time
        // announcement fires. The clock display is unaffected.
        guard appSettings.announcementsEnabled else { return }

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
            at: now,
            settings: settings,
            schedule: appSettings.schedule,
            isMuted: appSettings.isMuted,
            isAway: appSettings.desk.isAwayActive
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

        // Hand off to the shared coordinator: sound (chime count from the
        // boundary) and/or speech, at time priority.
        let job = AudioAnnouncementCoordinator.Job(
            sound: settings.playSound ? settings.sound : nil,
            soundCount: settings.playSound ? boundary.soundCount : 0,
            speech: settings.speakTime
                ? SpeechAnnouncer.phrase(for: now, format: appSettings.timeFormat)
                : nil,
            voiceIdentifier: settings.voiceIdentifier,
            priority: .time
        )
        AudioAnnouncementCoordinator.shared.submit(job)

        // A normal announcement just fired, so there's nothing for a
        // catch-up to stand in for.
        pendingMicCatchUp = false
        lastFiredMinute = minuteKey
    }

    /// Mic freed (after MicActivityService's release cooldown). If a
    /// boundary was swallowed by the mic while it was live, speak the
    /// *current* time once as a catch-up — speech only, and only if the
    /// shared gate is now open (inside the window, not snoozed). Submitted
    /// at time priority so on a combined flush it precedes the desk nudge.
    private func handleMicReleased() {
        guard pendingMicCatchUp else { return }
        pendingMicCatchUp = false

        let appSettings = SettingsManager.shared.settings
        let settings = appSettings.announcement
        let now = Date()
        guard settings.enabled,
              settings.speakTime,
              appSettings.audioGateOpen(at: now, micInUse: false)
        else { return }

        AudioAnnouncementCoordinator.shared.submit(.init(
            sound: nil,
            soundCount: 0,
            speech: SpeechAnnouncer.phrase(for: now, format: appSettings.timeFormat),
            voiceIdentifier: settings.voiceIdentifier,
            priority: .time
        ))
    }
}
