import Foundation

/// Writes a transactionally-consistent snapshot of the live items database into
/// the Sync-backed data dir (one-way backup / new-hardware migration). Uses
/// SQLite `VACUUM INTO`, which produces a single clean file and cannot run
/// inside a transaction — hence `writeWithoutTransaction`. The live DB stays
/// machine-local. Snapshots are debounced after changes and flushed on quit.
final class ItemBackupCoordinator {
    static let shared = ItemBackupCoordinator()

    /// Coalesce a burst of edits into one snapshot this long after they settle.
    private let debounce: TimeInterval = 120
    private var timer: Timer?
    private var dirty = false

    private init() {}

    /// Note that the items database changed and (re)arm the debounced snapshot.
    /// Safe to call from any thread; timer state is managed on the main thread.
    func itemsDidChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.dirty = true
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(
                withTimeInterval: self.debounce, repeats: false
            ) { [weak self] _ in
                self?.snapshot()
            }
        }
    }

    /// Synchronously snapshot if dirty. Call from `applicationWillTerminate` so
    /// the final state is always backed up even if the debounce hadn't fired.
    func flushSync() {
        timer?.invalidate()
        timer = nil
        snapshot()
    }

    private func snapshot() {
        guard dirty else { return }
        let destination = AssistAntPaths.itemsBackupURL
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try ItemsDatabase.shared.dbQueue.writeWithoutTransaction { db in
                // VACUUM INTO requires the destination not to exist.
                try? FileManager.default.removeItem(at: destination)
                try db.execute(sql: "VACUUM INTO ?", arguments: [destination.path])
            }
            dirty = false
        } catch {
            NSLog("ItemBackupCoordinator: snapshot failed: \(error.localizedDescription)")
        }
    }
}
