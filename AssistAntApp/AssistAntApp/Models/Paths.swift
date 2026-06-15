import Foundation

/// Mirror of tools/assist-ant/src/assist_ant/paths.cr. The two
/// sides must agree exactly on paths — that's the IPC contract.
enum AssistAntPaths {
    static var root: URL {
        if let override = env("ASSIST_ANT_ROOT") {
            return override
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".assist-ant", isDirectory: true)
    }

    static var dataDir: URL {
        env("ASSIST_ANT_DATA_DIR")
            ?? root.appendingPathComponent("data", isDirectory: true)
    }

    /// The agent's workspace — the cwd of the embedded Claude session and the
    /// home of its auto-loaded CLAUDE.md. Machine-local on purpose: its
    /// contents (CLAUDE.md, the agent skills, the SessionStart hook) are
    /// app-owned and regenerated on launch by WorkspaceInstaller /
    /// AgentHookInstaller, so nothing here is irreplaceable to sync — unlike
    /// `dataDir`, whose items backup is Sync-backed. Created by
    /// `ensureDirectories()`, so a fresh machine needs no manual setup.
    static var workspaceDir: URL {
        env("ASSIST_ANT_WORKSPACE_DIR")
            ?? root.appendingPathComponent("workspace", isDirectory: true)
    }

    static var runtimeDir: URL {
        env("ASSIST_ANT_RUNTIME_DIR")
            ?? root.appendingPathComponent("runtime", isDirectory: true)
    }

    static var socketPath: URL {
        env("ASSIST_ANT_SOCKET")
            ?? runtimeDir.appendingPathComponent("assist-ant.sock")
    }

    static var socketLockPath: URL {
        socketPath.appendingPathExtension("lock")
    }

    static var logDir: URL {
        runtimeDir.appendingPathComponent("logs", isDirectory: true)
    }

    /// Machine-local Application Support directory for AssistAnt. NOT the
    /// Sync-backed data dir — used for per-machine state. Mirrors where
    /// AgentStatePersistence stores agent-state.json.
    static var appSupportDir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AssistAnt", isDirectory: true)
    }

    /// The live items database. Machine-local on purpose: a live SQLite file
    /// must never sit under file-level sync. The backend (PocketBase) is the
    /// cross-device sync path; Syncthing only replicates the consistent
    /// snapshot at `itemsBackupURL`. Overridable via `ASSIST_ANT_ITEMS_DB`
    /// (e.g. for a sandboxed instance during testing).
    static var itemsDatabaseURL: URL {
        env("ASSIST_ANT_ITEMS_DB")
            ?? appSupportDir.appendingPathComponent("items.db")
    }

    /// Consistent backup snapshot of the items database, written into the
    /// Sync-backed data dir for one-way backup / new-hardware migration.
    /// Produced via VACUUM INTO so it is always transactionally consistent.
    static var itemsBackupURL: URL {
        dataDir.appendingPathComponent("items-backup.db")
    }

    /// Create all directories the app expects to exist.
    /// Idempotent. Called once at startup by AppDelegate.
    static func ensureDirectories() {
        for dir in [dataDir, runtimeDir, logDir, workspaceDir] {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
        }
    }

    private static func env(_ key: String) -> URL? {
        guard let v = ProcessInfo.processInfo.environment[key] else { return nil }
        return URL(fileURLWithPath: v)
    }
}
