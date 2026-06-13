import Foundation

/// Installs AssistAnt's SessionStart hook into the workspace by invoking
/// `assist-ant install-hooks` on launch. The merge logic lives in the CLI
/// (single source of truth, unit-tested); this just triggers it — mirroring how
/// `WorkspaceInstaller` seeds workspace files. Idempotent and best-effort: a
/// missing workspace or binary is a silent skip, never a launch failure.
enum AgentHookInstaller {
    static func installIfNeeded() {
        guard FileManager.default.fileExists(
            atPath: AssistAntPaths.workspaceDir.path
        ) else {
            NSLog("AgentHookInstaller: workspace missing — skipping")
            return
        }
        guard let bin = findBinary() else {
            NSLog("AgentHookInstaller: assist-ant binary not found — skipping")
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: bin)
        task.arguments = ["install-hooks"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            NSLog("AgentHookInstaller: failed to run install-hooks: \(error)")
        }
    }

    /// Resolve the installed `assist-ant` binary (same search order as
    /// `AgentSessionController.findBinaryPath`, minus the `which` fallback).
    private static func findBinary() -> String? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/assist-ant",
            "/usr/local/bin/assist-ant",
            "/opt/homebrew/bin/assist-ant",
        ]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }
}
