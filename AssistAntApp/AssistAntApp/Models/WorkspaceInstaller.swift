import Foundation

/// Installs app-owned files into the embedded agent's workspace on launch — the
/// project-memory `CLAUDE.md` and the agent skills. The app is the source of
/// truth: each file ships as a bundled resource and is written into the
/// workspace when the copy there is missing or has drifted from the bundled
/// one. Idempotent — it compares content and rewrites only on a mismatch, so it
/// doesn't churn the workspace. The workspace is a machine-local dir the app
/// creates in `ensureDirectories()`, so a fresh machine gets these files on
/// first launch.
///
/// `CLAUDE.md` is intentionally app-owned and drift-corrected, not hand-edited
/// in place: it carries load-bearing operating context a fresh install can't be
/// expected to author by hand, so it must ship with the app and self-heal.
enum WorkspaceInstaller {
    /// Bundled resource (name without extension) → path relative to the
    /// workspace root.
    private static let files: [(resource: String, destination: String)] = [
        ("WorkspaceMemory", "CLAUDE.md"),
        ("CaptureItemSkill", ".claude/skills/assist-ant-capture-item/SKILL.md"),
        ("ManageTasksSkill", ".claude/skills/assist-ant-manage-tasks/SKILL.md"),
    ]

    static func installIfNeeded() {
        let workspace = AssistAntPaths.workspaceDir
        // The app creates the workspace in `ensureDirectories()`; this guard is a
        // defensive skip if it's somehow absent, so we never write stray files.
        guard FileManager.default.fileExists(atPath: workspace.path) else {
            NSLog("WorkspaceInstaller: workspace missing — skipping install")
            return
        }
        for file in files { install(file) }
    }

    private static func install(_ file: (resource: String, destination: String)) {
        guard let src = Bundle.main.url(
            forResource: file.resource, withExtension: "md"
        ), let bundled = try? Data(contentsOf: src) else {
            NSLog("WorkspaceInstaller: bundled resource '\(file.resource)' not found")
            return
        }

        let dest = AssistAntPaths.workspaceDir
            .appendingPathComponent(file.destination)

        // Up to date — leave it alone (no churn on the synced workspace).
        if let existing = try? Data(contentsOf: dest), existing == bundled {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try bundled.write(to: dest, options: .atomic)
            NSLog("WorkspaceInstaller: installed/updated '\(file.destination)'")
        } catch {
            NSLog("WorkspaceInstaller: failed to install '\(file.destination)': \(error)")
        }
    }
}
