import Foundation
import GRDB

/// Owns the GRDB connection to the machine-local items database and runs
/// migrations. WAL journaling for durability and read/write concurrency.
final class ItemsDatabase {
    static let shared = ItemsDatabase()

    let dbQueue: DatabaseQueue

    private init() {
        do {
            let url = AssistAntPaths.itemsDatabaseURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var config = Configuration()
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
            }
            dbQueue = try DatabaseQueue(path: url.path, configuration: config)
            try Self.migrator.migrate(dbQueue)
        } catch {
            fatalError("ItemsDatabase: failed to open/migrate: \(error)")
        }
    }

    /// Test seam: drive a custom (e.g. in-memory) database through the same
    /// migrations.
    init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createItems") { db in
            try db.create(table: "items") { t in
                t.primaryKey("id", .text)
                t.column("tenant_id", .text).notNull()
                t.column("type", .text).notNull()
                t.column("title", .text).notNull()
                t.column("body", .text)
                t.column("source", .text).notNull()
                t.column("external_id", .text)
                t.column("type_data", .jsonText).notNull()
                t.column("iceboxed_at", .datetime)
                t.column("deleted_at", .datetime)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("server_updated_at", .datetime)
                t.column("pending", .boolean).notNull().defaults(to: false)
            }

            // Identity dedup for source-derived items. NULL external_id rows are
            // distinct under SQLite unique-index semantics, so many manual items
            // (source="manual", external_id=NULL) coexist freely. Raw SQL keeps
            // this independent of GRDB's version-specific index-creation API.
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_items_identity
                ON items (tenant_id, source, external_id)
                """)
            try db.execute(
                sql: "CREATE INDEX idx_items_tenant_type ON items (tenant_id, type)"
            )
            try db.execute(
                sql: "CREATE INDEX idx_items_updated ON items (updated_at)"
            )
        }

        // Cross-type schedule key: a zoneless local civil date (TEXT
        // "YYYY-MM-DD"; SQLite has no native date type). Powers the today
        // sidebar, a future calendar view, and window-scoped calendar prune.
        migrator.registerMigration("addScheduledOn") { db in
            try db.alter(table: "items") { t in
                t.add(column: "scheduled_on", .text)
            }
            try db.execute(
                sql: "CREATE INDEX idx_items_scheduled_on ON items (scheduled_on)"
            )
        }

        // Rename the per-row scope column tenant_id -> workspace_id. The concept
        // is an install identity ("which workspace this is"); "tenant" was
        // backend jargon that leaked into the column. RENAME COLUMN rewrites the
        // index column references automatically on modern SQLite, but the index
        // names still read "tenant", so the tenant-named indexes are recreated
        // under workspace names.
        migrator.registerMigration("renameTenantToWorkspace") { db in
            try db.execute(
                sql: "ALTER TABLE items RENAME COLUMN tenant_id TO workspace_id")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_items_identity")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_items_tenant_type")
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_items_identity
                ON items (workspace_id, source, external_id)
                """)
            try db.execute(
                sql: "CREATE INDEX idx_items_workspace_type ON items (workspace_id, type)")
        }

        // Seat the single workspace this install owns. The id lives on every
        // item row, so the workspace record lives in the same database; minting
        // it here (once) gives a stable opaque UUID with no runtime
        // normalization step. Rows written under the CLI's old literal "local"
        // scope are reassigned onto it — idempotent for a fresh install, where
        // the UPDATE matches nothing.
        migrator.registerMigration("seatWorkspace") { db in
            try db.create(table: "workspace") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            let now = Date()
            let id = UUID().uuidString.lowercased()
            try db.execute(
                sql: """
                    INSERT INTO workspace (id, name, created_at, updated_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [id, Workspace.defaultName(), now, now])
            try db.execute(
                sql: "UPDATE items SET workspace_id = ? WHERE workspace_id = 'local'",
                arguments: [id])
        }

        return migrator
    }
}
