import GRDB
import XCTest
@testable import Meepo

final class AppDatabaseTests: XCTestCase {
    private func makeDB() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        return db
    }

    private func insertProject(_ db: Database, path: String = "/tmp/a") throws -> Project {
        var project = Project(name: "a", path: path, remote: nil, color: nil)
        try project.insert(db)
        return project
    }

    private func makeSession(projectId: Int64, uuid: String = UUID().uuidString) -> Session {
        Session(projectId: projectId, claudeSessionId: uuid, model: "opus", branch: "main",
                status: .idle, createdAt: .now, lastActiveAt: .now)
    }

    func testSessionRoundTripKeepsStatusRawValue() throws {
        let db = try makeDB()
        try db.write { db in
            let project = try insertProject(db)
            var session = makeSession(projectId: project.id!)
            session.status = .waitingPermission
            try session.insert(db)
        }
        let raw = try db.read { try String.fetchOne($0, sql: "SELECT status FROM session") }
        XCTAssertEqual(raw, "waiting_permission") // spec's snake_case, not Swift case name
        let fetched = try db.read { try Session.fetchOne($0) }
        XCTAssertEqual(fetched?.status, .waitingPermission)
    }

    func testDeletingProjectDeletesItsSessions() throws {
        let db = try makeDB()
        try db.write { db in
            let project = try insertProject(db)
            var session = makeSession(projectId: project.id!)
            try session.insert(db)
            _ = try project.delete(db)
        }
        XCTAssertEqual(try db.read { try Session.fetchCount($0) }, 0)
    }

    func testSameFolderCannotBeAddedTwice() throws {
        let db = try makeDB()
        try db.write { db in _ = try insertProject(db, path: "/tmp/x") }
        XCTAssertThrowsError(try db.write { db in _ = try insertProject(db, path: "/tmp/x") })
    }

    func testClaudeSessionIdIsUnique() throws {
        let db = try makeDB()
        let uuid = UUID().uuidString
        try db.write { db in
            let project = try insertProject(db)
            var s1 = makeSession(projectId: project.id!, uuid: uuid)
            try s1.insert(db)
        }
        XCTAssertThrowsError(try db.write { db in
            var s2 = makeSession(projectId: 1, uuid: uuid)
            try s2.insert(db)
        })
    }
}
