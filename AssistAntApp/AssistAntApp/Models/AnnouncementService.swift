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
/// first, never overlapping) and one gate. Cancelling on silence is owned
/// by the coordinator; this service only handles the catch-up for when
/// silence lifts.
final class AnnouncementService {
    static let shared = AnnouncementService()

    private var clockObserver: AnyCancellable?
    private var muteObserver: AnyCancellable?
    private var lastFiredMinute: Date?

    /// Set when a boundary that would otherwise have fired was suppressed by
    /// a temporary silence — a live mic, the manual mute, or being away. When
    /// that silence lifts (and the gate is otherwise open), this triggers a
    /// one-shot spoken catch-up of the current time so the user isn't left
    /// unaware of the time afterwards. In-memory only — a pending catch-up
    /// does not survive relaunch. A single flag, not a queue: any number of
    /// suppressed boundaries yields at most one catch-up, because
    /// re-announcing the current time answers all of them at once.
    private var pendingCatchUp = false

    private init() {
        clockObserver = ClockService.shared.$currentTime
            .sink { [weak self] now in
                self?.evaluate(at: now)
            }

        // The coordinator owns cancel-on-silence, so this service only reacts
        // to silence *ending* (the mic release already debounced by
        // MicActivityService), where the spoken catch-up fires.
        muteObserver = TemporaryMuteMonitor.shared.didLift
            .sink { [weak self] in self?.handleSilenceLifted() }
    }

    /// Pure decision: is `now` a minute the user asked to have announced?
    /// Returns the boundary type so the caller knows how many chimes to play,
    /// or nil when this minute is not one. Side-effect-free.
    ///
    /// Scope is the standing schedule alone — master enable, interval, and the
    /// announcement-hours window. The temporary silencers (a live mic, the
    /// manual mute, being away) are deliberately absent: a boundary they
    /// swallow still has to arm a catch-up, and folding them in here would
    /// leave the caller unable to tell "not a boundary" apart from "a boundary
    /// that was silenced" — the two answers a catch-up depends on separating.
    ///
    /// It does not check `playSound` — that only decides which outputs the
    /// submitted job carries.
    static func dueBoundary(
        at now: Date,
        settings: AnnouncementSettings,
        announcementHours: AnnouncementHours,
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

        // Announcement-hours gate: is today's slot active right now?
        let timeOfDay = TimeOfDay(hour: hour, minute: minute)
        guard announcementHours.isActive(at: timeOfDay, weekday: weekday)
        else { return nil }

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

        // The standing schedule only. Temporary silence is applied below
        // instead, so a boundary it swallows can arm a catch-up rather than
        // being lost here.
        guard let boundary = Self.dueBoundary(
            at: now,
            settings: settings,
            announcementHours: appSettings.announcementHours
        ) else { return }

        // Early-out if neither output is on. Still mark the minute as
        // fired so subsequent ticks within the same minute don't
        // reconsider.
        guard settings.playSound || settings.speakTime else {
            lastFiredMinute = minuteKey
            return
        }

        // Temporary silence: suppress this boundary and remember it so a
        // spoken catch-up can stand in for it when the silence lifts.
        // Out-of-window and a disabled master switch never reach here —
        // `dueBoundary` already refused them — so a catch-up only ever stands
        // in for an announcement an interruption swallowed.
        if appSettings.isTemporarilySilenced(
            micInUse: MicActivityService.shared.isMicInUse
        ) {
            pendingCatchUp = true
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
        pendingCatchUp = false
        lastFiredMinute = minuteKey
    }

    /// Temporary silence ended. If a boundary was swallowed while it held,
    /// speak the *current* time once as a catch-up — speech only, and only if
    /// the shared gate is now open (inside the window, master switch on).
    /// Submitted at time priority so on a combined flush it precedes the desk
    /// nudge.
    private func handleSilenceLifted() {
        guard pendingCatchUp else { return }
        pendingCatchUp = false

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
