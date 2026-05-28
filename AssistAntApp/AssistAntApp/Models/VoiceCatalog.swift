import AVFoundation
import Foundation

/// Curated access to the system's installed speech voices. Keeps
/// `AVFoundation` imports out of the View layer.
///
/// `localeVoices` powers the voice picker — voices whose `language`
/// prefix matches the user's current locale. The full cross-locale
/// catalog is intentionally not exposed: the system locale's voices
/// are what users actually want and the wider list adds clutter
/// without value. Entries are sorted by display name and carry a
/// parenthesized locale tag ("Samantha (en-US)") so co-language
/// voices stay distinguishable.
enum VoiceCatalog {

    /// Voices matching the user's current locale, e.g. all en-* voices
    /// for an en-US user. Sorted by display name.
    static func localeVoices() -> [VoiceEntry] {
        let prefix = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            .map(VoiceEntry.init)
            .sorted { $0.displayName < $1.displayName }
    }

    /// Resolve a stored identifier back into a voice. nil identifier
    /// or unresolvable identifier returns nil; the caller hands that
    /// straight to `AVSpeechUtterance.voice`, which then falls back
    /// to the system default voice for the utterance's locale.
    static func voice(
        forIdentifier identifier: String?
    ) -> AVSpeechSynthesisVoice? {
        guard let id = identifier else { return nil }
        return AVSpeechSynthesisVoice(identifier: id)
    }
}

/// A row in the voice picker. Wraps the underlying voice's identifier
/// (the persisted value) and a display string built from the voice's
/// `name` plus a parenthesized locale tag.
struct VoiceEntry: Identifiable, Hashable {
    let id: String        // AVSpeechSynthesisVoice.identifier
    let displayName: String

    init(voice: AVSpeechSynthesisVoice) {
        self.id = voice.identifier
        // "Samantha (en-US)" rather than just "Samantha" so cross-locale
        // duplicates are distinguishable when the "Show all" toggle is on.
        self.displayName = "\(voice.name) (\(voice.language))"
    }
}
