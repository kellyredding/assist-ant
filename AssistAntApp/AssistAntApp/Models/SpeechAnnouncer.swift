import AVFoundation
import Foundation

/// Speaks a time announcement through `AVSpeechSynthesizer`. Singleton
/// so the underlying synthesizer outlives any single utterance — a
/// short-lived local synthesizer is GC'd before speech completes,
/// cutting off mid-word.
///
/// Phase 2: invoked from `AnnouncementService.evaluate` after the
/// chime sequence finishes, and from `AnnounceCard`'s preview button.
/// Last-write-wins: a new `speak(...)` call stops any in-flight
/// utterance immediately so rapid taps on preview don't queue speech.
final class SpeechAnnouncer {
    static let shared = SpeechAnnouncer()

    private let synthesizer = AVSpeechSynthesizer()

    private init() {}

    /// Speak the time `date` using `format` to choose 12/24-hour, with
    /// the given voice identifier (nil = system default). A previous
    /// in-flight utterance is stopped immediately so rapid invocations
    /// don't queue — matches `SoundSequencer`'s last-write-wins
    /// behavior. The utterance's `rate` is left at
    /// `AVSpeechUtteranceDefaultSpeechRate` (0.5); per-voice rate
    /// tuning produced uneven cadence across voices and the slider
    /// was removed in favor of trusting each voice's natural pace.
    func speak(
        time date: Date,
        format: TimeFormat,
        voiceIdentifier: String?
    ) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let phrase = Self.phrase(for: date, format: format)
        let utterance = AVSpeechUtterance(string: phrase)
        utterance.voice = VoiceCatalog.voice(forIdentifier: voiceIdentifier)
        synthesizer.speak(utterance)
    }

    /// Build the spoken phrase for `date`.
    ///
    /// 12-hour mode drops the `:00` minutes at the top of the hour so
    /// it reads "It's 3 PM" rather than "It's 3:00 PM". 24-hour mode
    /// keeps minutes always — "It's 15 o'clock" sounds wrong, but
    /// "It's 15:00" reads cleanly through the synthesizer.
    static func phrase(for date: Date, format: TimeFormat) -> String {
        let calendar = Calendar.current
        let components = calendar.dateComponents(
            [.hour, .minute], from: date
        )
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0

        switch format {
        case .twelveHour:
            let displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
            let period = hour < 12 ? "AM" : "PM"
            if minute == 0 {
                return "It's \(displayHour) \(period)"
            } else {
                let mm = String(format: "%02d", minute)
                return "It's \(displayHour):\(mm) \(period)"
            }

        case .twentyFourHour:
            let mm = String(format: "%02d", minute)
            return "It's \(hour):\(mm)"
        }
    }
}
