import Foundation

/// Per-feature audio settings for upcoming-calendar-item announcements.
/// Mirrors `AnnouncementSettings`/`DeskSettings`: a master `enabled`, two
/// independent output toggles (`playSound`, `speakEvent`), a sound choice,
/// and a voice. The calendar-specific knobs are `leadMinutes` (which
/// "minutes before the event" announcements fire) and `announceStart` (the
/// event-start announcement, the lead-0 case, toggled independently).
///
/// `sound` defaults to `.hero` — distinct from the time chime (`.glass`)
/// and the desk nudge (`.funk`) so an event announcement is audibly its
/// own thing.
struct CalendarAnnouncementSettings: Codable, Equatable {
    var enabled: Bool
    var leadMinutes: Set<Int>   // minutes-before presets currently selected
    var announceStart: Bool     // announce at the event's start (lead 0)
    var playSound: Bool
    var sound: AnnouncementSound
    var speakEvent: Bool
    var voiceIdentifier: String?

    /// Lead-time options offered by the settings checklist, in display
    /// order. The stored `leadMinutes` is any subset of these.
    static let leadPresets: [Int] = [1, 5, 10, 15, 30]

    static let defaults = CalendarAnnouncementSettings(
        enabled: false,
        leadMinutes: [5, 15],
        announceStart: true,
        playSound: true,
        sound: .hero,
        speakEvent: true,
        voiceIdentifier: nil
    )
}

// MARK: - Backward-compatible decoding

extension CalendarAnnouncementSettings {
    private enum CodingKeys: String, CodingKey {
        case enabled, leadMinutes, announceStart, playSound, sound,
             speakEvent, voiceIdentifier
    }

    /// Missing keys fall back to `.defaults` so a prefs.json written before
    /// a field existed decodes cleanly. Declared in an extension so the
    /// memberwise init (used by `.defaults`) survives.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CalendarAnnouncementSettings.defaults
        self.enabled = try c.decodeIfPresent(
            Bool.self, forKey: .enabled
        ) ?? d.enabled
        self.leadMinutes = try c.decodeIfPresent(
            Set<Int>.self, forKey: .leadMinutes
        ) ?? d.leadMinutes
        self.announceStart = try c.decodeIfPresent(
            Bool.self, forKey: .announceStart
        ) ?? d.announceStart
        self.playSound = try c.decodeIfPresent(
            Bool.self, forKey: .playSound
        ) ?? d.playSound
        self.sound = try c.decodeIfPresent(
            AnnouncementSound.self, forKey: .sound
        ) ?? d.sound
        self.speakEvent = try c.decodeIfPresent(
            Bool.self, forKey: .speakEvent
        ) ?? d.speakEvent
        self.voiceIdentifier = try c.decodeIfPresent(
            String.self, forKey: .voiceIdentifier
        ) ?? d.voiceIdentifier
    }
}
