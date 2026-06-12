import Foundation
import Combine

/// Drives the standing-desk timer's state transitions and its audible
/// nudge. The timer's data lives in `SettingsManager.shared.settings.desk`;
/// this service owns the writes so the UI, menu bar, and the audio path
/// all go through one place.
///
/// Visual is never gated (the views derive the countdown/nudge live from
/// `DeskSettings.timerPhase(at:)`). Audio is: while a nudge is pending the
/// service runs a 20s repeat timer, and each tick submits the desk nudge
/// to `AudioAnnouncementCoordinator` only if `AppSettings.audioGateOpen`
/// (inside the schedule window, not snoozed, mic free). The nudge is
/// audio-only and never surfaces the app window, so it cannot pull focus
/// away from whatever app is in front.
final class DeskService {
    static let shared = DeskService()

    private var clockObserver: AnyCancellable?
    private var micObserver: AnyCancellable?
    private var repeatTimer: Timer?

    /// Cadence of the audible nudge repeat while a switch is pending.
    private static let nudgeRepeat: TimeInterval = 20.0

    private init() {
        // Minute tick: start/stop the audible repeat as the timer crosses
        // into / out of the nudge phase.
        clockObserver = ClockService.shared.$currentTime
            .sink { [weak self] _ in self?.evaluateNudge() }

        // Mic freeing: immediately re-attempt the desk audio so a pending
        // nudge resumes the instant a call ends (rather than waiting up to
        // 20s for the next repeat tick). The coordinator owns
        // cancel-on-mic-engage, and `fireDeskAudioIfAllowed` re-checks the
        // gate, so this is a no-op when no nudge is pending.
        micObserver = MicActivityService.shared.$isMicInUse
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in self?.fireDeskAudioIfAllowed() }
    }

    /// One-time consistency fixup at launch: if the desk was left
    /// enabled but somehow has no start time, start a fresh timer so a
    /// phase can be computed. Then evaluate so a nudge pending on launch
    /// begins its audible repeat. Normal prefs.json always has a start
    /// time when enabled; the fixup is defense in depth.
    func start() {
        let desk = SettingsManager.shared.settings.desk
        if desk.enabled, desk.positionStartedAt == nil {
            SettingsManager.shared.settings.desk.positionStartedAt = Date()
        }
        evaluateNudge()
    }

    /// Toggle the feature. Enabling always starts a *fresh* timer in
    /// the last-known position (sitting by default on first-ever
    /// enable) — no immediate nudge. Disabling leaves the position
    /// remembered; `timerPhase` reports `.inactive` while off, and a
    /// later enable starts fresh. Re-evaluates so the audible repeat
    /// starts/stops immediately rather than at the next tick.
    func setEnabled(_ enabled: Bool) {
        var desk = SettingsManager.shared.settings.desk
        desk.enabled = enabled
        if enabled {
            desk.positionStartedAt = Date()
            // Away is global and outranks the timer, so enabling the timer
            // does not clear it — if you're away, you stay away until you
            // tap "I'm back at my desk".
        }
        SettingsManager.shared.settings.desk = desk
        evaluateNudge()
    }

    /// "I switched" / "Switch now": flip to the opposite position and
    /// start its interval. Clears any pending nudge implicitly (the
    /// new `positionStartedAt` resets the derived phase to counting) and
    /// stops the audible repeat at once.
    func acknowledgeSwitch() {
        var desk = SettingsManager.shared.settings.desk
        guard desk.enabled else { return }
        desk.currentPosition = desk.currentPosition.opposite
        desk.positionStartedAt = Date()
        SettingsManager.shared.settings.desk = desk
        evaluateNudge()
    }

    /// Step away from the desk. Sets the global away flag, which mutes
    /// announcements (and pauses the timer if it is running) until the user
    /// returns. Works whether or not the desk timer is enabled — away is a
    /// global concept. Not time-bound; there is no auto-return.
    func goAway() {
        var desk = SettingsManager.shared.settings.desk
        desk.isAway = true
        SettingsManager.shared.settings.desk = desk
        evaluateNudge()
    }

    /// "I'm back at my desk": clear the away state and start a *fresh sit
    /// interval* — you just sat back down, so no nudge accrued while away.
    func returnToDesk() {
        var desk = SettingsManager.shared.settings.desk
        desk.isAway = false
        desk.currentPosition = .sitting
        desk.positionStartedAt = Date()
        SettingsManager.shared.settings.desk = desk
        evaluateNudge()
    }

    /// Start the audible repeat on entering the nudge phase, stop it on
    /// leaving. Idempotent: while already nudging it leaves the running
    /// timer alone (no restart, no re-raise). Away has no auto-return —
    /// the user resumes only by tapping "I'm back at my desk".
    private func evaluateNudge() {
        let desk = SettingsManager.shared.settings.desk
        let now = Date()

        if case .nudge = desk.timerPhase(at: now) {
            if repeatTimer == nil {
                fireDeskAudioIfAllowed()      // first audible attempt
                startRepeatTimer()
            }
        } else {
            // Covers .away, .counting, .inactive — no audible repeat.
            stopRepeatTimer()
        }
    }

    private func startRepeatTimer() {
        // `.common` run-loop mode so it keeps firing through the settings
        // modal / menu tracking, like ClockService's ticker.
        let timer = Timer(timeInterval: Self.nudgeRepeat, repeats: true) {
            [weak self] _ in self?.fireDeskAudioIfAllowed()
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private func stopRepeatTimer() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    /// Submit the desk nudge audio if a nudge is pending and the shared
    /// gate is open. Audio only — it deliberately does not surface or
    /// activate the app window, so a nudge never interrupts work in
    /// another app; the user relies on the audible cue.
    private func fireDeskAudioIfAllowed() {
        let appSettings = SettingsManager.shared.settings
        let desk = appSettings.desk
        guard case .nudge(let from) = desk.timerPhase(at: Date()) else {
            return
        }
        guard appSettings.audioGateOpen(
            at: Date(), micInUse: MicActivityService.shared.isMicInUse
        ) else { return }
        guard desk.playSound || desk.speakAlert else { return }

        AudioAnnouncementCoordinator.shared.submit(.init(
            sound: desk.playSound ? desk.sound : nil,
            soundCount: desk.playSound ? 1 : 0,
            speech: desk.speakAlert ? "Time to \(from.opposite.verb)" : nil,
            voiceIdentifier: desk.voiceIdentifier,
            priority: .desk
        ))
    }
}
