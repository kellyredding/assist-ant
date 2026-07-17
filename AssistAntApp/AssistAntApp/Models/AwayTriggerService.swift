import AppKit

/// Flips AssistAnt into "away from desk" automatically when the screen
/// locks or the machine goes to sleep, and back to "at my desk" when the
/// screen is unlocked — so the away-mute protects you whenever you step
/// away and lifts the moment you return.
///
/// The return is bound to *unlock*, not wake: waking the machine may leave
/// the screen still locked, so waking alone is not a reliable "back at desk"
/// signal. Only an actual unlock returns you, and only when you were away —
/// an unlock with no preceding step-away (login, fast user switch) leaves an
/// active desk interval untouched rather than resetting it.
///
/// Away is global (independent of the desk timer — see DeskSettings), so
/// this works whether or not the standing-desk timer is enabled.
///
/// Notes on the triggers:
/// - Screen lock / unlock post `com.apple.screenIsLocked` /
///   `com.apple.screenIsUnlocked` on the *distributed* notification center
///   (not NSWorkspace). They fire only when locking actually locks (i.e. a
///   password is required on lock / screensaver).
/// - `NSWorkspace.willSleepNotification` covers full *system* sleep, not
///   display-only sleep; that is a separate signal and intentionally not
///   handled here. There is deliberately no wake trigger — unlock is the
///   only return signal (see above).
final class AwayTriggerService {
    static let shared = AwayTriggerService()

    private var lockObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?

    private init() {}

    /// Begin observing lock + unlock + sleep. Idempotent. Called once at
    /// launch.
    func start() {
        guard lockObserver == nil, unlockObserver == nil,
            sleepObserver == nil else { return }

        lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.enterAway(reason: "screen locked")
        }

        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.exitAway(reason: "screen unlocked")
        }

        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.enterAway(reason: "system sleep")
        }
    }

    private func enterAway(reason: String) {
        AssistAntLog.info("Auto-away triggered (\(reason))")
        DeskService.shared.goAway(auto: true)
    }

    /// Auto-return on unlock, but only for an away we entered automatically
    /// (lock / sleep). A manual step-away must survive a lock/unlock cycle —
    /// the user chose to be away, so only they clear it. This also skips an
    /// unlock with no preceding away (a login or fast user switch), which
    /// would otherwise reset the position and restart the interval and
    /// clobber a running desk timer for no reason.
    private func exitAway(reason: String) {
        let desk = SettingsManager.shared.settings.desk
        guard desk.isAway, desk.awayWasAutomatic else { return }
        AssistAntLog.info("Auto-return triggered (\(reason))")
        DeskService.shared.returnToDesk()
    }

    deinit {
        if let o = lockObserver {
            DistributedNotificationCenter.default().removeObserver(o)
        }
        if let o = unlockObserver {
            DistributedNotificationCenter.default().removeObserver(o)
        }
        if let o = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
    }
}
