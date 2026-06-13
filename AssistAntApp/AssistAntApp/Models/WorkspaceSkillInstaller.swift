import Foundation

/// Installs app-owned agent skills into the workspace on launch. The app is
/// the source of truth: each skill ships as a bundled resource and is written
/// into `~/.assist-ant/workspace/.claude/skills/<name>/SKILL.md` when the
/// workspace copy is missing or has drifted from the bundled one. Idempotent —
/// it compares content and rewrites only on a mismatch, so it doesn't churn
/// the Sync-backed workspace. A new machine that has the workspace symlink but
/// no skills gets them on first launch.
enum WorkspaceSkillInstaller {
    /// Bundled resource (name without extension) → workspace skill folder name.
    private static let skills: [(resource: String, name: String)] = [
        ("SyncCalendarSkill", "assist-ant-sync-calendar-items"),
        ("SyncLinearSkill", "assist-ant-sync-linear-items"),
        ("CaptureItemSkill", "assist-ant-capture-item"),
    ]

    static func installIfNeeded() {
        let workspace = AssistAntPaths.workspaceDir
        // The workspace is a manually-set-up (Sync-backed) symlink. If it isn't
        // present the agent can't run anyway, so don't create stray dirs.
        guard FileManager.default.fileExists(atPath: workspace.path) else {
            NSLog("WorkspaceSkillInstaller: workspace missing — skipping skill install")
            return
        }
        for skill in skills { install(skill) }
    }

    private static func install(_ skill: (resource: String, name: String)) {
        guard let src = Bundle.main.url(
            forResource: skill.resource, withExtension: "md"
        ), let bundled = try? Data(contentsOf: src) else {
            NSLog("WorkspaceSkillInstaller: bundled skill '\(skill.resource)' not found")
            return
        }

        let dir = AssistAntPaths.workspaceDir
            .appendingPathComponent(
                ".claude/skills/\(skill.name)", isDirectory: true)
        let dest = dir.appendingPathComponent("SKILL.md")

        // Up to date — leave it alone (no churn on the synced workspace).
        if let existing = try? Data(contentsOf: dest), existing == bundled {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            try bundled.write(to: dest, options: .atomic)
            NSLog("WorkspaceSkillInstaller: installed/updated skill '\(skill.name)'")
        } catch {
            NSLog("WorkspaceSkillInstaller: failed to install '\(skill.name)': \(error)")
        }
    }
}
