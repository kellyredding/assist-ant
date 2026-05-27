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

    /// Create all directories the app expects to exist.
    /// Idempotent. Called once at startup by AppDelegate.
    static func ensureDirectories() {
        for dir in [dataDir, runtimeDir, logDir] {
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
