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
/// screen identity, and the resizable sidebar fraction — no UserDefaults
/// dependency.
struct PersistedWindowState: Codable {
    let version: Int
    let windowFrame: PersistedWindowFrame
    let screenIdentifier: String
    let screenFrame: PersistedScreenFrame
    /// Sidebar width as a fraction of the window (0.25–0.50). Absent from
    /// window-state.json files written before the fraction model shipped;
    /// such files decode with the default below so an old file restores
    /// cleanly.
    let sidebarFraction: Double
    /// Raw value of the last-selected MainTab. Absent from files written
    /// before tabs shipped; decodes to nil so the navigator falls back to its
    /// default.
    let selectedMainTab: String?

    init(
        version: Int,
        windowFrame: PersistedWindowFrame,
        screenIdentifier: String,
        screenFrame: PersistedScreenFrame,
        sidebarFraction: Double,
        selectedMainTab: String?
    ) {
        self.version = version
        self.windowFrame = windowFrame
        self.screenIdentifier = screenIdentifier
        self.screenFrame = screenFrame
        self.sidebarFraction = sidebarFraction
        self.selectedMainTab = selectedMainTab
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        windowFrame = try c.decode(
            PersistedWindowFrame.self, forKey: .windowFrame
        )
        screenIdentifier = try c.decode(
            String.self, forKey: .screenIdentifier
        )
        screenFrame = try c.decode(
            PersistedScreenFrame.self, forKey: .screenFrame
        )
        // Backward-compat: fall back to the default when the key is absent.
        sidebarFraction = try c.decodeIfPresent(
            Double.self, forKey: .sidebarFraction
        ) ?? Double(SidebarMetrics.defaultFraction)
        selectedMainTab = try c.decodeIfPresent(
            String.self, forKey: .selectedMainTab
        )
    }
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

    /// Latest sidebar fraction to persist. Seeded from disk on first read via
    /// `loadSidebarFraction()` and updated by `saveSidebarFraction(_:)`.
    /// Window-state writes include this so a frame change never drops a
    /// freshly-set fraction (and vice versa).
    private var sidebarFraction: Double = Double(SidebarMetrics.defaultFraction)

    /// Latest selected main-tab raw value to persist. Seeded on first read
    /// via `loadSelectedMainTab()` and updated by `saveSelectedMainTab(_:)`.
    private var selectedMainTab: String?

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
            ),
            sidebarFraction: sidebarFraction,
            selectedMainTab: selectedMainTab
        )

        scheduleDebouncedFlush()
    }

    /// Persist a new sidebar fraction. Updates the in-memory copy and
    /// schedules a debounced write through the same coalescing path as
    /// window-frame changes, so the write merges with any pending frame write
    /// instead of racing it. Clamps defensively to the allowed band.
    func saveSidebarFraction(_ fraction: CGFloat) {
        let clamped = min(
            max(fraction, SidebarMetrics.minFraction),
            SidebarMetrics.maxFraction
        )
        sidebarFraction = Double(clamped)
        isDirty = true

        // Rebuild currentState with the new fraction when we already have a
        // frame snapshot; otherwise the next saveWindowState picks it up.
        // Keeps a fraction-only change persistable even if the window hasn't
        // moved yet.
        if let existing = currentState {
            currentState = PersistedWindowState(
                version: existing.version,
                windowFrame: existing.windowFrame,
                screenIdentifier: existing.screenIdentifier,
                screenFrame: existing.screenFrame,
                sidebarFraction: sidebarFraction,
                selectedMainTab: selectedMainTab
            )
        }

        scheduleDebouncedFlush()
    }

    /// The persisted sidebar fraction, or the default if no file exists yet or
    /// it predates the fraction model. Also seeds the in-memory copy so a
    /// later window-state write carries the same value.
    func loadSidebarFraction() -> CGFloat {
        let raw = load()?.sidebarFraction
            ?? Double(SidebarMetrics.defaultFraction)
        // Clamp into the allowed band so any out-of-range value snaps back in.
        let clamped = min(
            max(CGFloat(raw), SidebarMetrics.minFraction),
            SidebarMetrics.maxFraction
        )
        sidebarFraction = Double(clamped)
        return clamped
    }

    /// Persist the selected main-tab raw value. Coalesces through the same
    /// debounced write as window-frame and sidebar-fraction changes.
    func saveSelectedMainTab(_ rawValue: String) {
        selectedMainTab = rawValue
        isDirty = true
        if let existing = currentState {
            currentState = PersistedWindowState(
                version: existing.version,
                windowFrame: existing.windowFrame,
                screenIdentifier: existing.screenIdentifier,
                screenFrame: existing.screenFrame,
                sidebarFraction: existing.sidebarFraction,
                selectedMainTab: selectedMainTab
            )
        }
        scheduleDebouncedFlush()
    }

    /// The persisted selected main-tab raw value, or nil if none was saved.
    /// Also seeds the in-memory copy so a later window-state write carries it.
    func loadSelectedMainTab() -> String? {
        let raw = load()?.selectedMainTab
        selectedMainTab = raw
        return raw
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

    /// Schedule the trailing-debounce (1s) + max-cap (3s) flush pair. Shared
    /// by `saveWindowState(for:)` and `saveSidebarWidth(_:)` so both write
    /// paths coalesce through one timer set.
    private func scheduleDebouncedFlush() {
        // Reset trailing timer on every change (1s after last change).
        trailingTimer?.invalidate()
        trailingTimer = Timer.scheduledTimer(
            withTimeInterval: Self.trailingDebounce,
            repeats: false
        ) { [weak self] _ in
            self?.flush()
        }

        // Start the max-cap timer if not already running (3s ceiling).
        if maxCapTimer == nil {
            maxCapTimer = Timer.scheduledTimer(
                withTimeInterval: Self.maxDelayCap,
                repeats: false
            ) { [weak self] _ in
                self?.flush()
            }
        }
    }

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
