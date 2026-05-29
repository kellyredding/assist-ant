import AVFoundation
import Foundation

/// Speaks arbitrary text through `AVSpeechSynthesizer`. Singleton so the
/// underlying synthesizer outlives any single utterance — a short-lived
/// local synthesizer is GC'd before speech completes, cutting off
/// mid-word.
///
/// Owned by `AudioAnnouncementCoordinator` for scheduled announcements
/// (which passes a `completion` so the coordinator knows when an
/// utterance finishes), and called directly by the settings previews
/// (which pass no completion). Last-write-wins: a new `speak(...)` call
/// stops any in-flight utterance immediately.
///
/// `phrase(for:format:)` stays here as the time-phrase builder; the desk
/// nudge supplies its own short phrase ("Time to stand").
final class SpeechAnnouncer: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechAnnouncer()

    private let synthesizer = AVSpeechSynthesizer()
    private var completion: (() -> Void)?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speak arbitrary `text` with the given voice (nil = system
    /// default), calling `completion` when the utterance finishes or is
    /// cancelled. A new call stops any in-flight utterance first; the
    /// previous utterance's completion fires (via the cancel delegate)
    /// before the new one is set.
    func speak(
        text: String,
        voiceIdentifier: String?,
        completion: (() -> Void)? = nil
    ) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        self.completion = completion
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = VoiceCatalog.voice(forIdentifier: voiceIdentifier)
        synthesizer.speak(utterance)
    }

    /// Stop any in-flight utterance immediately and fire its completion.
    /// Used to abort speech when the microphone goes live mid-announcement
    /// so it doesn't leak into a call.
    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        fireCompletion()
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        fireCompletion()
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        fireCompletion()
    }

    /// Fire the pending completion at most once (nils it first), so the
    /// stop()/delegate double-path can't invoke it twice.
    private func fireCompletion() {
        let c = completion
        completion = nil
        c?()
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
