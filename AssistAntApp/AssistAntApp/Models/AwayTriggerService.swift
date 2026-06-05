import AppKit

/// Flips AssistAnt into "away from desk" automatically when the screen
/// locks or the machine goes to sleep, so the away-mute protects you
/// whenever you step away.
///
/// One-way by design: unlocking or waking does NOT auto-return — you clear
/// away yourself with "I'm back at my desk". The intent is protection
/// (silence announcements while you're gone), and a manual return avoids
/// un-muting the moment the screen wakes for an unrelated reason.
///
/// Away is global (independent of the desk timer — see DeskSettings), so
/// this works whether or not the standing-desk timer is enabled.
///
/// Notes on the triggers:
/// - Screen lock posts `com.apple.screenIsLocked` on the *distributed*
///   notification center (not NSWorkspace). It fires only when locking
///   actually locks (i.e. a password is required on lock / screensaver).
/// - `NSWorkspace.willSleepNotification` covers full *system* sleep, not
///   display-only sleep; that is a separate signal and intentionally not
///   handled here.
final class AwayTriggerService {
    static let shared = AwayTriggerService()

    private var lockObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?

    private init() {}

    /// Begin observing lock + sleep. Idempotent. Called once at launch.
    func start() {
        guard lockObserver == nil, sleepObserver == nil else { return }

        lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.enterAway(reason: "screen locked")
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
        DeskService.shared.goAway()
    }

    deinit {
        if let o = lockObserver {
            DistributedNotificationCenter.default().removeObserver(o)
        }
        if let o = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
    }
}
