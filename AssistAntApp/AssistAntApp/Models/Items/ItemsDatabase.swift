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
        return migrator
    }
}
