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

    /// Stop any in-flight utterance immediately. Used to abort speech
    /// when the microphone goes live mid-announcement so it doesn't
    /// leak into a call.
    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    /// Build the spoken phrase for `date`.
    ///
    /// 12-hour mode omits AM/PM entirely — at the top of the hour it
    /// reads "It's 3 o'clock", otherwise "It's 3:30". (A bare "It's 3"
    /// at the top of the hour reads too abruptly, so the o'clock form
    /// stands in for the dropped period.)
    ///
    /// 24-hour mode reads as military time, with every component
    /// spelled out so the pronunciation is deterministic across voices
    /// rather than left to the synthesizer's reading of "15:00" or
    /// "15:30": "It's oh eight hundred", "It's fifteen hundred", "It's
    /// oh eight thirty", "It's fifteen oh five", "It's zero hundred"
    /// at midnight.
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
            if minute == 0 {
                return "It's \(displayHour) o'clock"
            } else {
                let mm = String(format: "%02d", minute)
                return "It's \(displayHour):\(mm)"
            }

        case .twentyFourHour:
            return "It's \(military(hour: hour, minute: minute))"
        }
    }

    /// Spoken military-time form for a 24-hour value. The top of the
    /// hour ends in "hundred" ("oh eight hundred", "fifteen hundred");
    /// off the hour reads the minute after the hour ("oh eight thirty",
    /// "fifteen oh five").
    private static func military(hour: Int, minute: Int) -> String {
        let hourPart = militaryHour(hour)
        if minute == 0 {
            return "\(hourPart) hundred"
        }
        return "\(hourPart) \(militaryMinute(minute))"
    }

    /// Hour component of military time. Hours 1–9 take an "oh" prefix
    /// ("oh eight"); 10–23 read plainly ("fifteen"); midnight is "zero"
    /// rather than the redundant "oh zero". Spelled out via
    /// NumberFormatter so the synthesizer says the word instead of
    /// guessing at "08".
    private static func militaryHour(_ hour: Int) -> String {
        if hour == 0 {
            return "zero"
        }
        let word = spelledOut(hour)
        return hour < 10 ? "oh \(word)" : word
    }

    /// Minute component of military time. Minutes 1–9 take an "oh"
    /// prefix ("oh five"); 10–59 read plainly ("thirty",
    /// "forty-five"). Minute 0 is handled by the caller (it becomes
    /// "hundred" on the hour), so this is only reached for 1–59.
    private static func militaryMinute(_ minute: Int) -> String {
        let word = spelledOut(minute)
        return minute < 10 ? "oh \(word)" : word
    }

    /// English spelled-out form of a non-negative integer, e.g. 8 →
    /// "eight", 15 → "fifteen". Locale is pinned to en_US so the word
    /// matches the surrounding hardcoded-English phrase regardless of
    /// the system locale.
    private static func spelledOut(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }
}
