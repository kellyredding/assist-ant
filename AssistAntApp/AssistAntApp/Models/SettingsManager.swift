import Foundation
import Combine

/// Singleton store for AppSettings. Loads from
/// ~/.assist-ant/data/prefs.json on init, persists changes back via a
/// trailing-debounced timer. The `data/` directory is a symlink into the
/// user's Syncthing folder so the file rides the user's external sync setup
/// automatically.
///
/// Mirrors the singleton + @Published + trailing-debounce pattern used by
/// Galaxy's SettingsManager
/// (~/projects/kellyredding/galaxy/GalaxyApp/GalaxyApp/Models/SettingsManager.swift).
final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var settings: AppSettings

    private var saveCancellable: AnyCancellable?
    private let saveQueue = DispatchQueue(
        label: "com.kellyredding.AssistAnt.settings-save"
    )

    private var fileURL: URL {
        AssistAntPaths.dataDir.appendingPathComponent("prefs.json")
    }

    private init() {
        // Load from disk, falling back to defaults on any error.
        if let loaded = Self.load(from: AssistAntPaths.dataDir
                .appendingPathComponent("prefs.json")) {
            self.settings = loaded
        } else {
            self.settings = .current
        }

        // Trailing-debounce: any change to `settings` schedules a save 500ms
        // later. Rapid edits collapse into one write.
        saveCancellable = $settings
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: saveQueue)
            .sink { [weak self] newSettings in
                self?.persist(newSettings)
            }
    }

    private static func load(from url: URL) -> AppSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }

    private func persist(_ settings: AppSettings) {
        do {
            try FileManager.default.createDirectory(
                at: AssistAntPaths.dataDir,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)

            // Atomic write via temp + rename so a crashed write doesn't
            // leave a half-written prefs.json on disk (especially
            // important since the file lives inside the user's synced
            // folder).
            let tempURL = fileURL
                .deletingLastPathComponent()
                .appendingPathComponent("prefs.json.tmp")
            try data.write(to: tempURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
        } catch {
            NSLog("SettingsManager: failed to persist prefs.json: \(error.localizedDescription)")
        }
    }
}
