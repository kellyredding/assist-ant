import AppKit

// MARK: - Persisted Data Structures

/// Screen frame for proportional scaling when the original screen is no
/// longer available at restore time.
struct PersistedScreenFrame: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// Window frame (position + size) for full restoration.
struct PersistedWindowFrame: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// Complete window state persisted to disk. Owns all window position, size,
/// and screen identity — no UserDefaults dependency.
struct PersistedWindowState: Codable {
    let version: Int
    let windowFrame: PersistedWindowFrame
    let screenIdentifier: String
    let screenFrame: PersistedScreenFrame
}

// MARK: - Persistence Manager

/// Manages persistence of window screen state to disk. All public methods
/// must be called on the main thread.
///
/// Adapted verbatim from Galaxy's WindowStatePersistence
/// (~/projects/kellyredding/galaxy/GalaxyApp/GalaxyApp/Models/WindowStatePersistence.swift).
/// State lives in ~/Library/Application Support/AssistAnt/window-state.json
/// rather than the synced data directory — window placement is per-machine.
final class WindowStatePersistence {
    static let shared = WindowStatePersistence()

    /// Trailing debounce: write after 1s of no changes.
    private static let trailingDebounce: TimeInterval = 1.0

    /// Max delay cap: force write after 3s of sustained changes.
    private static let maxDelayCap: TimeInterval = 3.0

    private let fileURL: URL
    private var isDirty = false
    private var trailingTimer: Timer?
    private var maxCapTimer: Timer?
    private var currentState: PersistedWindowState?

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
        self.fileURL = appDir.appendingPathComponent("window-state.json")
    }

    // MARK: - Public API

    /// Save the current window frame and screen identity. Coalesces rapid
    /// updates via a trailing-debounce + max-cap timer pair so a 5-second
    /// drag writes once, not 60 times.
    func saveWindowState(for window: NSWindow) {
        guard let screen = window.screen else { return }

        isDirty = true

        currentState = PersistedWindowState(
            version: 1,
            windowFrame: PersistedWindowFrame(
                x: window.frame.origin.x,
                y: window.frame.origin.y,
                width: window.frame.size.width,
                height: window.frame.size.height
            ),
            screenIdentifier: screen.localizedName,
            screenFrame: PersistedScreenFrame(
                x: screen.frame.origin.x,
                y: screen.frame.origin.y,
                width: screen.frame.size.width,
                height: screen.frame.size.height
            )
        )

        // Reset trailing timer on every change (1s after last change).
        trailingTimer?.invalidate()
        trailingTimer = Timer.scheduledTimer(
            withTimeInterval: Self.trailingDebounce,
            repeats: false
        ) { [weak self] _ in
            self?.flush()
        }

        // Start max-cap timer if not already running (3s ceiling).
        if maxCapTimer == nil {
            maxCapTimer = Timer.scheduledTimer(
                withTimeInterval: Self.maxDelayCap,
                repeats: false
            ) { [weak self] _ in
                self?.flush()
            }
        }
    }

    /// Flush pending state to disk asynchronously.
    func flush() {
        guard isDirty, let state = currentState else { return }
        isDirty = false
        cancelTimers()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.writeToDisk(state)
        }
    }

    /// Flush synchronously — blocks until write completes. Used in
    /// applicationWillTerminate so a quit-mid-drag still records the final
    /// frame.
    func flushSync() {
        guard isDirty, let state = currentState else { return }
        isDirty = false
        cancelTimers()
        writeToDisk(state)
    }

    /// Load persisted state from disk. Returns nil on first launch, missing
    /// file, or corrupt data.
    func load() -> PersistedWindowState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(
                PersistedWindowState.self,
                from: data
            )
        } catch {
            NSLog("WindowStatePersistence: failed to load: \(error)")
            return nil
        }
    }

    // MARK: - Private

    private func cancelTimers() {
        trailingTimer?.invalidate()
        trailingTimer = nil
        maxCapTimer?.invalidate()
        maxCapTimer = nil
    }

    private func writeToDisk(_ state: PersistedWindowState) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("WindowStatePersistence: failed to save: \(error)")
        }
    }
}
