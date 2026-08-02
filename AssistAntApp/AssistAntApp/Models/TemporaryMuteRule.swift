import Foundation

/// Whether audio is silenced for a reason a catch-up should stand in for.
///
/// Three of the conditions that close `AppSettings.audioGateOpen` are
/// *temporary*: a live microphone, the manual mute, and being away from the
/// desk. Each ends at a moment the user chooses or a call releases, and an
/// announcement swallowed by one is worth replaying then.
///
/// The announcement-hours window and the master enable are deliberately
/// absent. Both also silence audio, but neither is temporary in the same
/// sense — replaying a swallowed 8pm meeting reminder when the window opens at
/// 9am the next morning is noise rather than a service, and a disabled master
/// switch is a standing preference, not an interruption.
///
/// Takes primitives rather than `AppSettings` so it stays clear of that type's
/// Galactic-backed terminal fields and can be exercised in the smoke target.
/// The convenience over a settings snapshot lives beside `AppSettings` itself.
enum TemporaryMuteRule {
    static func isSilenced(
        muteWhileMicInUse: Bool,
        micInUse: Bool,
        isAway: Bool,
        isManuallyMuted: Bool
    ) -> Bool {
        if muteWhileMicInUse, micInUse { return true }
        if isAway { return true }
        if isManuallyMuted { return true }
        return false
    }
}
