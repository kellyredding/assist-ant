import Foundation

/// Thin facade for applying and clearing the global ad-hoc mute window on
/// `AppSettings`. Keeps the `SettingsManager` mutation in one place so
/// both the in-window status button and the menu bar item use the same
/// write path. The mute is global — it silences time announcements and
/// the desk nudge alike.
///
/// Stateless — every method just computes a new `muteUntil` and
/// writes it through `SettingsManager`. Persistence happens
/// automatically via `SettingsManager`'s `@Published` change
/// observation; no extra write plumbing required.
enum MuteController {

    /// Apply a preset mute duration starting now. Computes the
    /// expiry as `now + duration.timeInterval` and persists it.
    /// A new call while a mute is already in effect overwrites the
    /// previous `muteUntil` — durations do not accumulate.
    static func mute(for duration: MuteDuration, now: Date = Date()) {
        let until = now.addingTimeInterval(duration.timeInterval)
        SettingsManager.shared.settings.muteUntil = until
    }

    /// Clear the mute window immediately. Sets `muteUntil` to nil so
    /// the next announcement boundary fires normally.
    static func unmute() {
        SettingsManager.shared.settings.muteUntil = nil
    }

    /// Formatted end-time for the current mute, e.g. "3:45 PM" or
    /// "15:45" depending on the user's `TimeFormat`. Returns nil
    /// when no mute is active (no `muteUntil`, or `muteUntil` is in
    /// the past). Used by both the in-window status row and the
    /// menu bar item's header text.
    static func currentMuteEndDisplay(
        format: TimeFormat,
        now: Date = Date()
    ) -> String? {
        guard let until = SettingsManager.shared.settings.muteUntil,
              now < until else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.dateFormat = format.dateFormat
        return formatter.string(from: until)
    }
}
