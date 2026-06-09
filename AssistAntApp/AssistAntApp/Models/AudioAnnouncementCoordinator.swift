import Combine
import Foundation

/// Serializes every audible announcement so they never overlap and
/// always play in priority order (time before desk). Producers
/// (`AnnouncementService`, `DeskService`) build a `Job` and submit it;
/// the coordinator owns all `SoundSequencer` / `SpeechAnnouncer`
/// playback — producers never touch the players directly.
///
/// A job plays as: chimes (sound × count, 1s apart) then speech after
/// `count * 1s`, matching the established time-announcement cadence
/// (desk uses count 1). Completion is the speech finishing (via the
/// synthesizer delegate); for a sound-only job it's a short estimated
/// tail.
///
/// Desk nudges are coalesced: only one may be outstanding (in flight or
/// queued) at a time. A posture nudge is idempotent — a second "Time to
/// stand" tells the user nothing the pending one didn't — so dropping the
/// duplicate keeps a backlog from building while playback is stalled
/// (e.g. the audio route torn down across display/system sleep) and then
/// flushing as a burst of repeated nudges on return. Time announcements
/// and previews carry distinct content and are never coalesced.
final class AudioAnnouncementCoordinator {
    static let shared = AudioAnnouncementCoordinator()

    /// Higher rawValue plays first. Desk nudge is lowest; the time chime
    /// next; an upcoming-event announcement outranks both (specific,
    /// time-sensitive content shouldn't be starved behind a routine chime);
    /// a settings preview outranks all — when you tap it you want to hear it
    /// next, ahead of anything merely queued.
    enum Priority: Int { case desk = 0, time = 1, calendar = 2, preview = 3 }

    struct Job {
        var sound: AnnouncementSound?
        var soundCount: Int
        var speech: String?
        var voiceIdentifier: String?
        var priority: Priority
    }

    /// Beat between the chimes and the trailing speech, matching
    /// `SoundSequencer`'s inter-chime delay.
    private static let chimeBeat: TimeInterval = 1.0

    private var queue: [Job] = []
    private var isPlaying = false

    /// Priority of the job currently playing, `nil` while idle. Used to
    /// coalesce desk nudges: a new one is dropped while another is already
    /// in flight, not just while one waits in `queue`.
    private var playingPriority: Priority?
    private var pendingSpeechStart: DispatchWorkItem?
    private var micObserver: AnyCancellable?

    private init() {
        // Mic engaging cancels everything so a tail can't leak into a
        // call. Gated on the global toggle — when the user hasn't opted
        // into mic-muting, an in-flight announcement is left to finish.
        micObserver = MicActivityService.shared.$isMicInUse
            .removeDuplicates()
            .sink { [weak self] inUse in
                guard inUse,
                      SettingsManager.shared.settings.muteWhileMicInUse
                else { return }
                self?.cancelAll()
            }
    }

    /// Enqueue a job. Submissions made in the same run-loop turn (e.g. a
    /// mic-release flush where time + desk both fire) are coalesced before
    /// the first playback starts, so the priority sort orders them
    /// correctly regardless of which producer's observer fired first.
    func submit(_ job: Job) {
        // Coalesce desk nudges: collapse to a single outstanding job (in
        // flight or queued) so a stalled-playback backlog can't flush as a
        // burst of repeated "Time to stand" on return. See the type doc.
        if job.priority == .desk,
           playingPriority == .desk
               || queue.contains(where: { $0.priority == .desk }) {
            return
        }

        queue.append(job)
        queue.sort { $0.priority.rawValue > $1.priority.rawValue }
        DispatchQueue.main.async { [weak self] in self?.playNextIfIdle() }
    }

    /// Play a one-off settings preview (a sound, a spoken phrase, or both).
    /// Routed through the coordinator like every other producer so the
    /// coordinator stays the *single* client of the players — no preview
    /// can run concurrently with an announcement and strand the queue.
    /// Ungated by design: a preview is always audible when invoked, it
    /// just waits its turn behind whatever is currently playing.
    func preview(
        sound: AnnouncementSound?,
        speech: String?,
        voiceIdentifier: String?
    ) {
        submit(Job(
            sound: sound,
            soundCount: sound != nil ? 1 : 0,
            speech: speech,
            voiceIdentifier: voiceIdentifier,
            priority: .preview
        ))
    }

    /// Stop all playback and clear the queue immediately. Used on
    /// mic-engage so no announcement tail leaks into a call.
    func cancelAll() {
        queue.removeAll()
        pendingSpeechStart?.cancel()
        pendingSpeechStart = nil
        SoundSequencer.shared.stop()
        SpeechAnnouncer.shared.stop()
        isPlaying = false
        playingPriority = nil
    }

    private func playNextIfIdle() {
        guard !isPlaying, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        isPlaying = true
        playingPriority = job.priority
        play(job) { [weak self] in
            self?.isPlaying = false
            self?.playingPriority = nil
            self?.playNextIfIdle()
        }
    }

    private func play(_ job: Job, completion: @escaping () -> Void) {
        var speechDelay: TimeInterval = 0
        if let sound = job.sound, job.soundCount > 0 {
            SoundSequencer.shared.play(sound, count: job.soundCount)
            speechDelay = Double(job.soundCount) * Self.chimeBeat
        }

        guard let speech = job.speech else {
            // Sound-only: no speech to await, so complete after an
            // estimated tail past the last chime.
            let item = DispatchWorkItem { completion() }
            pendingSpeechStart = item
            DispatchQueue.main.asyncAfter(
                deadline: .now() + speechDelay + 1.0, execute: item
            )
            return
        }

        // Speech (the common, trailing element): start it after the
        // chimes, and let its completion drive the job's. The work item
        // is cancellable so a mid-chime cancelAll() can't let a queued
        // utterance fire after the mic engaged.
        let item = DispatchWorkItem {
            SpeechAnnouncer.shared.speak(
                text: speech, voiceIdentifier: job.voiceIdentifier
            ) { completion() }
        }
        pendingSpeechStart = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + speechDelay, execute: item
        )
    }
}
