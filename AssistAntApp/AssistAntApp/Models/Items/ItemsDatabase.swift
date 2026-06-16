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

        // Actionable items (todo/reminder/explore) share one resolution instant
        // and a manual-order key. `resolved_at` is the unified completed/
        // dismissed time (nil = active); `position` is the user's manual sort
        // order (nil = unset). Both nullable; unused by calendar rows.
        migrator.registerMigration("addResolvedAtAndPosition") { db in
            try db.alter(table: "items") { t in
                t.add(column: "resolved_at", .datetime)
                t.add(column: "position", .double)
            }
        }

        // The task system (see the AgentTask / TaskRun records). `tasks` holds a
        // named prompt + a trigger the heartbeat/runner read; `task_runs` is the
        // fire-and-forget log. Both live in this DB so the Tasks tab can surface
        // them and a later phase can sync them. Datetime columns are GRDB Date
        // (TEXT "YYYY-MM-DD HH:MM:SS.SSS"), same as the items table; `last_run_at`
        // is what the recurring due-eval reads for dedup/coalescing.
        migrator.registerMigration("createTasks") { db in
            try db.create(table: "tasks") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("trigger_type", .text).notNull()
                t.column("cadence_kind", .text)
                t.column("interval_seconds", .integer)
                t.column("daily_time", .text)
                t.column("run_at", .datetime)
                t.column("manual_key", .text)
                t.column("prompt", .text).notNull()
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("last_run_at", .datetime)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "task_runs") { t in
                // No FK to tasks: a run row outlives its task (task_id is a
                // nullable snapshot reference), so deleting a task leaves its
                // history intact in the log.
                t.primaryKey("id", .text)
                t.column("task_id", .text)
                t.column("task_name", .text).notNull()
                t.column("trigger", .text).notNull()
                t.column("fired_at", .datetime).notNull()
                t.column("status", .text).notNull()
                t.column("detail", .text)
            }
            // The log renders reverse-chronological by fired_at.
            try db.execute(
                sql: "CREATE INDEX idx_task_runs_fired ON task_runs (fired_at)")
        }

        // Per-machine persona selection. The persona the embedded agent loads is
        // install identity, so it lives on the workspace record (it travels with
        // the consistent backup snapshot), not in prefs.json. NOT NULL with a
        // constant default backfills the single seated row with the value the app
        // shipped with, so existing installs are unchanged.
        migrator.registerMigration("addWorkspacePersonaName") { db in
            try db.alter(table: "workspace") { t in
                t.add(column: "persona_name", .text)
                    .notNull()
                    .defaults(to: "assist-ant-work")
            }
        }

        // Seed the two built-in manual triggers backing the Today sync glyphs,
        // so they show in the Tasks tab and a glyph press / run-now logs against
        // a real row. Inserted once; they're ordinary rows the user can
        // rename/disable/delete (the glyph falls back to the coordinator if its
        // row is gone).
        migrator.registerMigration("seedBuiltinTasks") { db in
            let now = Date()
            func seed(_ name: String, _ key: String, _ prompt: String) throws {
                try db.execute(
                    sql: """
                        INSERT INTO tasks
                          (id, name, trigger_type, manual_key, prompt, enabled,
                           created_at, updated_at)
                        VALUES (?, ?, 'manual', ?, ?, 1, ?, ?)
                        """,
                    arguments: [
                        UUIDv7.generate(), name, key, prompt, now, now,
                    ])
            }
            // Frozen literals (not AgentTask constants): this past migration must
            // keep seeding the original key values regardless of later renames;
            // a follow-up migration promotes these rows to the `today` type.
            try seed("Calendar sync", "today_calendar_refresh", "Sync my calendar")
            try seed("Linear sync", "today_todo_refresh", "Sync my Linear issues")
        }

        // Cadence precision for recurring tasks. `weekdays` is an ISO-weekday
        // mask ("1,2,3,4,5", 1=Mon…7=Sun; NULL = every day) that narrows both
        // daily and interval recurrence; `window_start`/`window_end` ("HH:MM"
        // local) anchor an interval inside a daily window, so "every hour at :55
        // from 8 to 5" is one task instead of ten dailies. All nullable/additive,
        // so existing rows keep firing as every-day, no window. The Phase 4
        // due-eval reads these.
        migrator.registerMigration("addTaskCadencePrecision") { db in
            try db.alter(table: "tasks") { t in
                t.add(column: "weekdays", .text)
                t.add(column: "window_start", .text)
                t.add(column: "window_end", .text)
            }
        }

        // Snapshot the prompt as sent onto each run-log row, mirroring the
        // task_name snapshot, so the log can show a one-line preview of what was
        // delivered even after the task's prompt changes or the task is deleted.
        // Nullable: rows logged before this stay preview-less.
        migrator.registerMigration("addTaskRunPrompt") { db in
            try db.alter(table: "task_runs") { t in
                t.add(column: "prompt", .text)
            }
        }

        // Manual sort order for the Tasks list, mirroring items.position. The
        // Tasks tab orders by it (nulls last), so a CLI-authored task lands
        // unranked at the bottom in creation order until the user drags it.
        migrator.registerMigration("addTaskPosition") { db in
            try db.alter(table: "tasks") { t in
                t.add(column: "position", .double)
            }
        }

        // Promote the two glyph-bound built-ins from a keyed `manual` task to a
        // first-class `today` task, and rename the binding column to match:
        // `today_key` names which Today refresh glyph fires the task. (`manual`
        // is now keyless; `today` carries the key.) The key values shed their
        // now-redundant `today_` prefix.
        migrator.registerMigration("promoteBuiltinsToTodayTasks") { db in
            try db.execute(sql: "ALTER TABLE tasks RENAME COLUMN manual_key TO today_key")
            try db.execute(sql: """
                UPDATE tasks SET trigger_type = 'today', today_key = 'calendar_refresh'
                WHERE today_key = 'today_calendar_refresh'
                """)
            try db.execute(sql: """
                UPDATE tasks SET trigger_type = 'today', today_key = 'todo_refresh'
                WHERE today_key = 'today_todo_refresh'
                """)
        }

        return migrator
    }
}
