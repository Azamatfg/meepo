import Foundation
import GRDB

enum AppDatabase {
    /// Opens `~/.meepo/meepo.sqlite`, creating it and applying migrations.
    static func openShared() throws -> DatabaseQueue {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".meepo")
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

        return migrator
    }
}
