import Foundation

/// The 14 macOS system sounds, addressable via NSSound(named:).
/// AssistAnt does not bundle any custom audio assets — every value here
/// resolves to a file in /System/Library/Sounds/. Playback always goes
/// through `SoundSequencer` (driven by `AudioAnnouncementCoordinator`);
/// this type just identifies which sound.
enum AnnouncementSound: String, Codable, CaseIterable {
    case basso     = "Basso"
    case blow      = "Blow"
    case bottle    = "Bottle"
    case frog      = "Frog"
    case funk      = "Funk"
    case glass     = "Glass"
    case hero      = "Hero"
    case morse     = "Morse"
    case ping      = "Ping"
    case pop       = "Pop"
    case purr      = "Purr"
    case sosumi    = "Sosumi"
    case submarine = "Submarine"
    case tink      = "Tink"

    var displayName: String { rawValue }
}
