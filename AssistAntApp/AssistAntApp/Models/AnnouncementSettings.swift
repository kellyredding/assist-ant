import Foundation

/// Master enable, two independent output toggles (sound, speech), sound
/// choice, voice choice + rate, interval, schedule. The `enabled`
/// master toggle gates everything — when off, no announcements fire
/// regardless of the per-output toggles.
///
/// `playSound` and `speakTime` are peer toggles, both default-on
/// composable. Either, both, or neither can be on. When both are on,
/// the chime sequence plays first and speech follows after a delay
/// matched to the inter-chime cadence — see
/// `AnnouncementService.evaluate` for the orchestration.
///
/// Voice is persisted as the `AVSpeechSynthesisVoice.identifier`
/// string rather than the voice object itself (which is not Codable).
/// nil identifier means "use the system default voice" — see
/// `VoiceCatalog.voice(forIdentifier:)`. If a stored identifier later
/// fails to resolve (voice uninstalled), the synthesizer falls back to
/// the system default voice for the utterance's locale.
///
/// `muteUntil` is the ad-hoc-mute window's expiry. nil = not muted.
/// Non-nil = wall-clock time at which mute lifts. A past Date is
/// treated as not muted (the live check is just `now < muteUntil`).
/// Mute is gated as the final check in `AnnouncementService.shouldFire`
/// so it suppresses both sound and speech outputs atomically.
///
/// The weekly `schedule` and the `muteWhileMicInUse` toggle used to
/// live here but moved up to `AppSettings` — they are shared with the
/// desk timer, so they sit at the app level rather than looking
/// announcement-owned. `muteUntil` stays here for now; it has no second
/// consumer until desk audio lands.
struct AnnouncementSettings: Codable, Equatable {
    var enabled: Bool
    var playSound: Bool
    var sound: AnnouncementSound
    var speakTime: Bool
    var voiceIdentifier: String?
    var interval: AnnouncementInterval
    var muteUntil: Date?

    static let defaults = AnnouncementSettings(
        enabled: false,
        playSound: true,
        sound: .glass,
        speakTime: false,
        voiceIdentifier: nil,
        interval: .hourly,
        muteUntil: nil
    )
}

// MARK: - Backward-compatible decoding

extension AnnouncementSettings {
    private enum CodingKeys: String, CodingKey {
        case enabled, playSound, sound, speakTime, voiceIdentifier,
             interval, muteUntil
    }

    /// Custom decoder so a prefs.json written before this phase's
    /// fields existed (or by a future version that drops a field)
    /// decodes cleanly with the missing keys filled in from
    /// `.defaults`. Declared in an extension so the struct's
    /// synthesized memberwise initializer survives intact — that
    /// init is what `.defaults` calls.
    ///
    /// `AppSettings.init(from:)` already falls back when the whole
    /// `announcement` block is missing; this inner decoder handles
    /// the more common case where the block is present but is
    /// missing newer keys (Phase 1 → Phase 2 upgrade).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AnnouncementSettings.defaults
        self.enabled         = try c.decodeIfPresent(
            Bool.self,                 forKey: .enabled
        ) ?? d.enabled
        self.playSound       = try c.decodeIfPresent(
            Bool.self,                 forKey: .playSound
        ) ?? d.playSound
        self.sound           = try c.decodeIfPresent(
            AnnouncementSound.self,    forKey: .sound
        ) ?? d.sound
        self.speakTime       = try c.decodeIfPresent(
            Bool.self,                 forKey: .speakTime
        ) ?? d.speakTime
        self.voiceIdentifier = try c.decodeIfPresent(
            String.self,               forKey: .voiceIdentifier
        ) ?? d.voiceIdentifier
        self.interval        = try c.decodeIfPresent(
            AnnouncementInterval.self, forKey: .interval
        ) ?? d.interval
        self.muteUntil       = try c.decodeIfPresent(
            Date.self,                 forKey: .muteUntil
        ) ?? d.muteUntil
    }
}
