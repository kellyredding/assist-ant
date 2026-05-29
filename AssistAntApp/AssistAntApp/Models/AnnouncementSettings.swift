import Foundation

/// Master enable, two independent output toggles (sound, speech), sound
/// choice, voice choice, and interval. The `enabled` master toggle gates
/// everything — when off, no announcements fire regardless of the
/// per-output toggles.
///
/// `playSound` and `speakTime` are peer toggles, both default-on
/// composable. Either, both, or neither can be on. When both are on,
/// the chime sequence plays first and speech follows after a delay
/// matched to the inter-chime cadence — see
/// `AudioAnnouncementCoordinator` for the orchestration.
///
/// Voice is persisted as the `AVSpeechSynthesisVoice.identifier`
/// string rather than the voice object itself (which is not Codable).
/// nil identifier means "use the system default voice" — see
/// `VoiceCatalog.voice(forIdentifier:)`. If a stored identifier later
/// fails to resolve (voice uninstalled), the synthesizer falls back to
/// the system default voice for the utterance's locale.
///
/// The weekly `schedule`, the `muteWhileMicInUse` toggle, and the ad-hoc
/// `muteUntil` snooze all moved up to `AppSettings` — they are shared
/// with the desk timer (a snooze silences both features), so they sit at
/// the app level rather than looking announcement-owned.
struct AnnouncementSettings: Codable, Equatable {
    var enabled: Bool
    var playSound: Bool
    var sound: AnnouncementSound
    var speakTime: Bool
    var voiceIdentifier: String?
    var interval: AnnouncementInterval

    static let defaults = AnnouncementSettings(
        enabled: false,
        playSound: true,
        sound: .glass,
        speakTime: false,
        voiceIdentifier: nil,
        interval: .hourly
    )
}

// MARK: - Backward-compatible decoding

extension AnnouncementSettings {
    private enum CodingKeys: String, CodingKey {
        case enabled, playSound, sound, speakTime, voiceIdentifier, interval
    }

    /// Custom decoder so a prefs.json written before a field existed (or
    /// by a future version that drops a field) decodes cleanly with the
    /// missing keys filled in from `.defaults`. Declared in an extension
    /// so the struct's synthesized memberwise initializer survives intact
    /// — that init is what `.defaults` calls.
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
    }
}
