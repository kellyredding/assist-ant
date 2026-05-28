import Foundation

/// Phase 1 announcement settings: master enable, sound on/off, sound
/// choice, interval, schedule. Phase 2 will grow `speakTime: Bool` and a
/// voice picker. The `enabled` master toggle gates everything in either
/// phase — when off, no announcements fire regardless of other fields.
struct AnnouncementSettings: Codable, Equatable {
    var enabled: Bool
    var playSound: Bool
    var sound: AnnouncementSound
    var interval: AnnouncementInterval
    var schedule: WeeklySchedule

    static let defaults = AnnouncementSettings(
        enabled: false,
        playSound: true,
        sound: .glass,
        interval: .hourly,
        schedule: .workdayDefault
    )
}
