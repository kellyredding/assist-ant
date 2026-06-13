import Foundation

/// What a `session:ready` event should do to the tracked agent session.
struct SessionReconcileDecision: Equatable {
    /// Non-nil → persist this as the new resume target.
    var adoptId: String?
    /// Fire the gated post-resume reflow.
    var reflow: Bool
    /// The event didn't belong to the tracked agent (e.g. a sidecar) — ignore.
    var ignored: Bool
}

/// Pure derivation: decide how a `session:ready` event affects the embedded
/// agent's resume target. No I/O, no SwiftUI — unit-testable. This is the
/// analog of Galaxy's identifier-lineage matching, simplified for a single
/// tracked session via the SessionStart `source`.
enum SessionReconciler {
    /// - source: the SessionStart `source` (startup / resume / clear / compact).
    /// - reportedId: the session id the hook reported.
    /// - spawnedId: the id the app currently holds / spawned with.
    /// - awaitingResumeReady: a post-resume reflow is pending.
    static func decide(
        source: String, reportedId: String,
        spawnedId: String?, awaitingResumeReady: Bool
    ) -> SessionReconcileDecision {
        switch source {
        case "clear", "compact":
            // Only the interactive agent clears/compacts; reportedId is the new
            // current id. Adopt it if it changed. No reflow — these happen
            // mid-session, not at a resume.
            let adopt = reportedId != spawnedId ? reportedId : nil
            return SessionReconcileDecision(
                adoptId: adopt, reflow: false, ignored: false)
        case "startup", "resume":
            // The agent's own start/resume carries the id we spawned. A sidecar
            // session in the same workspace cwd reports an unrelated id — ignore
            // it so it can't stomp the resume target.
            guard reportedId == spawnedId else {
                return SessionReconcileDecision(
                    adoptId: nil, reflow: false, ignored: true)
            }
            return SessionReconcileDecision(
                adoptId: nil, reflow: awaitingResumeReady, ignored: false)
        default:
            return SessionReconcileDecision(
                adoptId: nil, reflow: false, ignored: true)
        }
    }
}
