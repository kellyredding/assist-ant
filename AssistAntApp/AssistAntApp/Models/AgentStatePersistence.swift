import Foundation

/// Persisted agent-session state. Holds the Claude session id so a relaunch
/// resumes the same conversation.
struct PersistedAgentState: Codable {
    let version: Int
    /// Lowercased UUID of the embedded agent's Claude session. Nil before
    /// the first session has ever been created on this machine.
    let sessionId: String?
}

/// Machine-local persistence for the embedded agent session id.
///
/// Stored in ~/Library/Application Support/AssistAnt/agent-state.json — NOT
/// the Sync-backed data directory. Rationale: Claude session transcripts
/// live per-machine under ~/.claude/projects/…, so a synced session id
/// would resolve to a transcript that does not exist on another machine and
/// `--resume` would fail. Keeping the id machine-local means a new machine
/// just starts a fresh session.
///
/// Pattern mirrors WindowStatePersistence (same app-support directory, same
/// atomic-write discipline). All methods are main-thread only.
final class AgentStatePersistence {
    static let shared = AgentStatePersistence()

    private let fileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let appDir = appSupport.appendingPathComponent(
            "AssistAnt",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: appDir,
            withIntermediateDirectories: true
        )
        self.fileURL = appDir.appendingPathComponent("agent-state.json")
    }

    /// The persisted session id, or nil on first launch / missing file /
    /// corrupt data.
    func loadSessionId() -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let state = try JSONDecoder().decode(
                PersistedAgentState.self, from: data
            )
            return state.sessionId
        } catch {
            NSLog("AgentStatePersistence: failed to load: \(error)")
            return nil
        }
    }

    /// Persist a session id. Atomic write so a crash mid-write can never
    /// leave a half-written file.
    func saveSessionId(_ sessionId: String) {
        let state = PersistedAgentState(version: 1, sessionId: sessionId)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("AgentStatePersistence: failed to save: \(error)")
        }
    }
}
