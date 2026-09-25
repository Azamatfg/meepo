import Foundation
import GRDB

enum AppDatabase {
    /// Opens `~/.meepo/meepo.sqlite`, creating it and applying migrations.
    static func openShared() throws -> DatabaseQueue {
        let dir = MeepoHome.url
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try DatabaseQueue(path: dir.appending(path: "meepo.sqlite").path)
        try migrator.migrate(db)
        return db
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "project") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("path", .text).notNull().unique()
                t.column("remote", .text)
                t.column("color", .text)
            }
            try db.create(table: "session") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("project", onDelete: .cascade).notNull()
                t.column("claudeSessionId", .text).notNull().unique()
                t.column("model", .text)
                t.column("branch", .text)
                t.column("status", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("lastActiveAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v2") { db in
            try db.create(table: "hookEvent") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("session", onDelete: .cascade).notNull()
                t.column("name", .text).notNull()
                t.column("summary", .text)
                t.column("isFailure", .boolean).notNull()
                t.column("createdAt", .datetime).notNull().indexed()
            }
        }

        migrator.registerMigration("v3") { db in
            try db.create(table: "usageRecord") { t in
                t.primaryKey("messageId", .text)
                t.column("claudeSessionId", .text).notNull().indexed()
                t.column("cwd", .text).notNull()
                t.column("model", .text).notNull()
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("isSidechain", .boolean).notNull()
                t.column("inputTokens", .integer).notNull()
                t.column("outputTokens", .integer).notNull()
                t.column("cacheCreationTokens", .integer).notNull()
                t.column("cacheReadTokens", .integer).notNull()
            }
            try db.create(table: "scanState") { t in
                t.primaryKey("path", .text)
                t.column("offset", .integer).notNull()
            }
        }

        // v3 kept the first streamed line of a response (undercounted output); rescan with max-per-field.
        migrator.registerMigration("v4-rescan-usage") { db in
            try db.execute(sql: "DELETE FROM usageRecord; DELETE FROM scanState")
        }

        migrator.registerMigration("v5-stages") { db in
            try db.alter(table: "session") { t in
                t.add(column: "effort", .text)
                t.add(column: "stage", .text)
            }
        }

        migrator.registerMigration("v6-worktrees-ports") { db in
            try db.alter(table: "session") { t in
                t.add(column: "worktreeName", .text)
                t.add(column: "worktreeBase", .text)
                t.add(column: "portBase", .integer)
            }
        }

        migrator.registerMigration("v7-tasks") { db in
            try db.create(table: "task") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("project", onDelete: .setNull)
                t.column("text", .text).notNull()
                t.column("note", .text).notNull().defaults(to: "")
                t.column("attachments", .jsonText).notNull().defaults(to: "[]")
                t.column("isDone", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("doneAt", .datetime)
                t.belongsTo("session", onDelete: .setNull)
            }
            try db.create(table: "agentTodo") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("project", onDelete: .cascade).notNull()
                t.column("file", .text).notNull()
                t.column("line", .text).notNull()
                t.column("createdAt", .datetime).notNull().indexed()
            }
        }

        migrator.registerMigration("v8-release-notes") { db in
            try db.create(table: "releaseNote") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("project", onDelete: .cascade).notNull()
                t.column("sha", .text).notNull()
                t.column("text", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v9-run-summaries") { db in
            try db.create(table: "runSummary") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("session", onDelete: .cascade).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("json", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["sessionId", "startedAt"])
            }
        }

        migrator.registerMigration("v10-session-names") { db in
            try db.alter(table: "session") { t in t.add(column: "name", .text) }
        }

        migrator.registerMigration("v11-extra-dirs") { db in
            try db.alter(table: "session") { t in t.add(column: "extraDirs", .text) }
        }

        return migrator
    }
}
