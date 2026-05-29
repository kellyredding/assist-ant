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

    /// Pending chime closures, tracked as cancellable work items so a
    /// `stop()` (e.g. the mic going live mid-sequence) can drop chimes
    /// that haven't fired yet, not just silence the ones already
    /// playing.
    private var pendingChimes: [DispatchWorkItem] = []

    private init() {}

    /// Play `sound` `count` times sequentially. `count <= 0` is a no-op.
    /// A new call while a sequence is in flight replaces the pending
    /// sequence (last-write-wins). `completion` (if given) fires after the
    /// last chime's audio is expected to end, and is cancelled by `stop()`
    /// along with the pending chimes.
    func play(
        _ sound: AnnouncementSound,
        count: Int,
        completion: (() -> Void)? = nil
    ) {
        guard count > 0 else { completion?(); return }
        stop()

        for i in 0..<count {
            let item = DispatchWorkItem { [weak self] in
                self?.playOne(sound)
            }
            pendingChimes.append(item)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Double(i) * Self.interChimeDelay,
                execute: item
            )
        }

        guard let completion else { return }
        // After the final chime's start offset plus its own duration.
        let lastStart = Double(count - 1) * Self.interChimeDelay
        let tail = NSSound(named: NSSound.Name(sound.rawValue))?.duration ?? 1.0
        let doneItem = DispatchWorkItem { completion() }
        pendingChimes.append(doneItem)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + lastStart + tail, execute: doneItem
        )
    }

    /// Cancel any not-yet-played chimes and silence any currently
    /// playing ones. Used to abort a sequence immediately — e.g. when
    /// the microphone goes live and an announcement must not leak into
    /// a call.
    func stop() {
        pendingChimes.forEach { $0.cancel() }
        pendingChimes.removeAll()
        activeSounds.forEach { $0.stop() }
        activeSounds.removeAll()
    }

    private func playOne(_ sound: AnnouncementSound) {
        guard let template = NSSound(named: NSSound.Name(sound.rawValue)),
              let ns = template.copy() as? NSSound
        else { return }
        activeSounds.append(ns)
        ns.play()
    }
}
