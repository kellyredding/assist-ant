import AppKit

/// Plays a chosen sound N times in succession, scheduling each chime's
/// start at a fixed delay after the previous one.
///
/// **Why the copy step**: `NSSound(named:)` returns a cached singleton
/// per sound name. Calling `.play()` on a still-playing NSSound is
/// silently ignored, which means rapid repeats of the same sound drop
/// chimes whenever the previous one hasn't finished. The fix is to make
/// a fresh independent NSSound via `.copy()` (NSSound conforms to
/// NSCopying) for every chime — each copy has its own playback state and
/// can play concurrently with or in rapid succession after any other
/// copy.
final class SoundSequencer {
    static let shared = SoundSequencer()

    /// Delay between successive chime starts. Tuned to feel rhythmic
    /// (grandfather-clock cadence) — each chime is clearly distinct from
    /// the next without dragging the sequence out.
    private static let interChimeDelay: TimeInterval = 1.0

    /// Active NSSound instances are retained here for the duration of
    /// their playback. ARC would otherwise release them at the end of
    /// their scheduled closure, possibly cutting playback short. Cleared
    /// at the start of each new sequence — by then any previous chimes
    /// have either finished (so dropping references is safe) or are
    /// being superseded by the new sequence anyway.
    private var activeSounds: [NSSound] = []

    private init() {}

    /// Play `sound` `count` times sequentially. `count <= 0` is a no-op.
    /// A new call while a sequence is in flight replaces the pending
    /// sequence (last-write-wins).
    func play(_ sound: AnnouncementSound, count: Int) {
        guard count > 0 else { return }
        activeSounds.removeAll()

        for i in 0..<count {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Double(i) * Self.interChimeDelay
            ) { [weak self] in
                self?.playOne(sound)
            }
        }
    }

    private func playOne(_ sound: AnnouncementSound) {
        guard let template = NSSound(named: NSSound.Name(sound.rawValue)),
              let ns = template.copy() as? NSSound
        else { return }
        activeSounds.append(ns)
        ns.play()
    }
}
