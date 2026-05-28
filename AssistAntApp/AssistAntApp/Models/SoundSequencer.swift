import AppKit

/// Plays a chosen sound N times in succession, chaining via NSSound's
/// `didFinishPlaying` delegate callback so the next chime starts exactly
/// when the previous one ends. Auto-adapts to whatever sound the user
/// picked — no overlap on long sounds (Submarine, Frog), no gap on short
/// ones (Tink, Pop).
final class SoundSequencer: NSObject, NSSoundDelegate {
    static let shared = SoundSequencer()

    private var pendingSound: AnnouncementSound?
    private var remaining: Int = 0

    private override init() { super.init() }

    /// Play `sound` `count` times sequentially. `count <= 0` is a no-op.
    /// A new call while a sequence is already playing replaces the
    /// pending sequence (last-write-wins) — acceptable for chimes that
    /// fire on minute boundaries, where overlapping requests indicate a
    /// new minute arriving before the previous chime finished.
    func play(_ sound: AnnouncementSound, count: Int) {
        guard count > 0 else { return }
        pendingSound = sound
        remaining = count
        playNext()
    }

    private func playNext() {
        guard remaining > 0,
              let sound = pendingSound,
              let ns = NSSound(named: NSSound.Name(sound.rawValue))
        else {
            pendingSound = nil
            remaining = 0
            return
        }
        ns.delegate = self
        remaining -= 1
        ns.play()
    }

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        playNext()
    }
}
