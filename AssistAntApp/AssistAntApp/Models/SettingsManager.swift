import Foundation
import Combine

/// Singleton store for AppSettings. Loads from
/// ~/.assist-ant/data/prefs.json on init; persists synchronously on every
/// change via didSet. The data directory is a symlink into the user's
/// Syncthing folder so prefs.json rides the user's external sync setup
/// automatically.
///
/// Persistence pattern mirrors Galaxy's SettingsManager
/// (~/projects/kellyredding/galaxy/GalaxyApp/GalaxyApp/Models/SettingsManager.swift):
/// `didSet { save() }` with a single atomic Data.write. Foundation's
/// `.atomic` flag writes to a sibling temp file and rename(2)s it into
/// place — the rename is atomic at the kernel level, so a crash mid-write
/// can never leave a half-written prefs.json on disk (especially important
/// since the file lives in the user's synced folder).
final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var settings: AppSettings {
        didSet {
            save()
            // Only on an actual change: the keybindings file is global and
            // shared with the companion app, so rewriting it because someone
            // picked a theme would stomp that app's bindings for no reason.
            if oldValue.textEntry != settings.textEntry {
                syncClaudeKeybindings()
            }
        }
    }

    /// Push the text-entry keystrokes into Claude Code's keybindings file.
    ///
    /// Failure is logged and swallowed. The file lives outside this app, may be
    /// read-only or owned by something else, and a settings change the user can
    /// see succeed in the card must not fail because a file elsewhere could not
    /// be written. The settings pane reports sync state separately.
    func syncClaudeKeybindings() {
        do {
            let result = try ClaudeKeybindingsWriter.sync(settings.textEntry)
            if result.alreadyInSync {
                AssistAntLog.dbg("keybindings", "already in sync")
            } else {
                AssistAntLog.dbg(
                    "keybindings",
                    "wrote \(result.written.count) binding(s) to "
                        + ClaudeKeybindingsWriter.fileURL.path
                )
            }
            for keystroke in result.unsupported {
                AssistAntLog.dbg(
                    "keybindings",
                    "\(keystroke.displayLabel) has no Claude Code spelling — "
                        + "it works in the composers but not the session pane"
                )
            }
        } catch {
            AssistAntLog.dbg("keybindings", "sync failed — \(error)")
        }
    }

    /// Replace the text-entry keystrokes with the ones the keybindings file
    /// carries. The file wins, wholesale.
    ///
    /// Adopting deliberately writes the file back, which reads oddly until you
    /// look at what the alternative leaves behind. The adopted keystrokes came
    /// from the file, so the two already agree on those; what the file may still
    /// be missing is an explicit unbind on a key Claude Code binds by default.
    /// Without the write-back the card would report a difference the instant
    /// after adopting, over a key the user never touched.
    ///
    /// Refuses when the file holds a binding the settings model cannot
    /// represent, rather than adopting the rest and dropping it silently.
    @discardableResult
    func adoptClaudeKeybindings() -> Bool {
        let state = ClaudeKeybindingsWriter.fileState(for: settings.textEntry)
        guard state.adoptable, let adopted = state.adopted else {
            AssistAntLog.dbg(
                "keybindings",
                "adopt refused — \(state.adoptRefusal ?? "nothing to adopt")"
            )
            return false
        }
        settings.textEntry = TextEntryBindings(
            submit: Self.merging(
                into: settings.textEntry.submit, adopted.submit),
            newline: Self.merging(
                into: settings.textEntry.newline, adopted.newline)
        ).coercingEmptyLists()
        syncClaudeKeybindings()
        AssistAntLog.dbg("keybindings", "adopted the session pane's keystrokes")
        return true
    }

    /// Fold adopted keystrokes into an existing list, keeping the order already
    /// there and appending only what is new.
    ///
    /// Rebuilding the list outright would reorder keystrokes that did not
    /// change, because the adopted set arrives in the file's alphabetical order
    /// rather than the user's. Cosmetic on its own, but these lists compare
    /// element-wise, so a reshuffle reads as a real edit and adopting a file
    /// that already agreed would stop being the no-op it ought to be.
    private static func merging(
        into current: [Keystroke], _ adopted: [Keystroke]
    ) -> [Keystroke] {
        let incoming = Set(adopted)
        return current.filter(incoming.contains)
            + adopted.filter { !current.contains($0) }
    }

    private var fileURL: URL {
        AssistAntPaths.dataDir.appendingPathComponent("prefs.json")
    }

    private init() {
        let url = AssistAntPaths.dataDir.appendingPathComponent("prefs.json")
        if let loaded = Self.load(from: url) {
            self.settings = loaded
        } else {
            self.settings = .current
        }

        // Guarantee the reserved machine-submit chord before anything can send
        // a prompt. Only that one binding — never the user's keystrokes — so a
        // launch cannot stomp what the companion app last wrote to this shared
        // file. This is what lets automated submission stop reasoning about
        // whether a sync has happened.
        do {
            if try ClaudeKeybindingsWriter.ensureReservedBinding() {
                AssistAntLog.dbg(
                    "keybindings", "added the reserved machine-submit binding")
            }
        } catch {
            AssistAntLog.dbg(
                "keybindings",
                "could not ensure the reserved binding — \(error)"
            )
        }
    }

    private static func load(from url: URL) -> AppSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: AssistAntPaths.dataDir,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("SettingsManager: failed to save prefs.json: \(error.localizedDescription)")
        }
    }
}
