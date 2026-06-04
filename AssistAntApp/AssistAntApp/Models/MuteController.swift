import Foundation

/// Thin facade for applying and clearing the global manual mute on
/// `AppSettings`. Keeps the `SettingsManager` mutation in one place so
/// both the in-window status button and the menu bar item use the same
/// write path. The mute is global — it silences time announcements and
/// the desk nudge alike — and open-ended: it stays until the user
/// explicitly unmutes.
///
/// Stateless — every method just flips `isMuted` and writes it through
/// `SettingsManager`. Persistence happens automatically via
/// `SettingsManager`'s `@Published` change observation; no extra write
/// plumbing required.
enum MuteController {

    /// Mute announcements until the user unmutes. Idempotent.
    static func mute() {
        SettingsManager.shared.settings.isMuted = true
    }

    /// Clear the mute so the next announcement boundary fires normally.
    static func unmute() {
        SettingsManager.shared.settings.isMuted = false
    }
}
