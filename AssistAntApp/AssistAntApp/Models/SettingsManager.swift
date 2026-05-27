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
        }
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
