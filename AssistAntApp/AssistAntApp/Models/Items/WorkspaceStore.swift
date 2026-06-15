import Foundation
import Combine
import GRDB

/// Reads and mutates the single workspace row. The row is seated by the
/// database migration; `current()` reads it, with a defensive get-or-create
/// backstop in case it is ever absent. `observe()` powers the title-bar pill
/// and the settings field; `rename(to:)` stamps `updatedAt`.
final class WorkspaceStore {
    static let shared = WorkspaceStore()

    private let dbQueue: DatabaseQueue

    private init() { self.dbQueue = ItemsDatabase.shared.dbQueue }

    /// Test seam: drive a migrated (e.g. in-memory) queue.
    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    /// The install's workspace. Seated by migration, so the common path is a
    /// plain read; the write-side get-or-create is a backstop against an absent
    /// row (and is safe under a concurrent race via the re-check).
    func current() throws -> Workspace {
        if let existing = try dbQueue.read({ db in try Workspace.fetchOne(db) }) {
            return existing
        }
        return try dbQueue.write { db in
            if let existing = try Workspace.fetchOne(db) { return existing }
            let workspace = Workspace.make()
            try workspace.insert(db)
            return workspace
        }
    }

    /// Rename the workspace. No-op if the row is somehow absent.
    func rename(to name: String) throws {
        try dbQueue.write { db in
            guard var workspace = try Workspace.fetchOne(db) else { return }
            workspace.name = name
            workspace.updatedAt = Date()
            try workspace.update(db)
        }
    }

    /// Set the persona the embedded agent loads on its next fresh session.
    /// No-op if the row is somehow absent. Stamps `updatedAt`.
    func setPersonaName(_ name: String) throws {
        try dbQueue.write { db in
            guard var workspace = try Workspace.fetchOne(db) else { return }
            workspace.personaName = name
            workspace.updatedAt = Date()
            try workspace.update(db)
        }
    }

    /// Live workspace updates for the settings field and the title-bar pill.
    func observe() -> AnyPublisher<Workspace?, Error> {
        ValueObservation
            .tracking { db in try Workspace.fetchOne(db) }
            .publisher(in: dbQueue)
            .eraseToAnyPublisher()
    }
}
