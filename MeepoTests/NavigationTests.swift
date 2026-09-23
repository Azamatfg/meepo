import GRDB
import XCTest
@testable import Meepo

/// Session creation, ordering, hotkey navigation and restore — without launching claude.
@MainActor
final class NavigationTests: XCTestCase {
    private var db: DatabaseQueue!
    private var store: AppStore!

    override func setUp() async throws {
        db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        store = makeIsolatedStore(db: db)
    }

    /// Adds repos named so that sidebar order (by name) differs from insertion order.
    private func addProjects(_ names: [String]) throws -> [Int64] {
        for name in names {
            let repo = try makeTempRepo()
            let named = repo.deletingLastPathComponent().appending(path: "\(name)-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: repo, to: named)
            try store.addProject(at: named)
        }
        return names.map { name in store.projects.first { $0.name.hasPrefix(name + "-") }!.id! }
    }

    func testCreateSessionRecordsBranchAndSelectsIt() throws {
        let (p) = try addProjects(["alpha"])[0]
        try store.createSession(projectId: p, model: "opus", prompt: "hi")
        let s = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(s.branch, "trunk")
        XCTAssertEqual(s.model, "opus")
        XCTAssertEqual(store.selectedSessionId, s.id)
        XCTAssertNotNil(UUID(uuidString: s.claudeSessionId))
        XCTAssertEqual(s.claudeSessionId, s.claudeSessionId.lowercased())
    }

    func testOrderFollowsSidebarNotCreationTime() throws {
        let ids = try addProjects(["zeta", "alpha"])
        try store.createSession(projectId: ids[0], model: nil, prompt: nil) // zeta first by time
        try store.createSession(projectId: ids[1], model: nil, prompt: nil)
        XCTAssertEqual(store.orderedSessions.map(\.projectId), [ids[1], ids[0]]) // alpha first by name
    }

    func testOffsetNavigationWrapsBothWays() throws {
        let p = try addProjects(["alpha"])[0]
        for _ in 0..<3 { try store.createSession(projectId: p, model: nil, prompt: nil) }
        let ids = store.orderedSessions.map(\.id)
        store.selectedSessionId = ids[2]
        store.selectSession(offset: 1)
        XCTAssertEqual(store.selectedSessionId, ids[0])
        store.selectSession(offset: -1)
        XCTAssertEqual(store.selectedSessionId, ids[2])
    }

    func testNumberSelectionIsOneBasedAndIgnoresMissing() throws {
        let p = try addProjects(["alpha"])[0]
        for _ in 0..<2 { try store.createSession(projectId: p, model: nil, prompt: nil) }
        let ids = store.orderedSessions.map(\.id)
        store.selectSession(number: 1)
        XCTAssertEqual(store.selectedSessionId, ids[0])
        store.selectSession(number: 9)
        XCTAssertEqual(store.selectedSessionId, ids[0])
    }

    func testNextWaitingSkipsIdleAndWraps() throws {
        let p = try addProjects(["alpha"])[0]
        for _ in 0..<3 { try store.createSession(projectId: p, model: nil, prompt: nil) }
        let ids = store.orderedSessions.map(\.id)
        try db.write { try $0.execute(sql: "UPDATE session SET status = 'waiting_permission' WHERE id = ?", arguments: [ids[0]]) }
        store.reload()
        store.selectedSessionId = ids[1]
        store.selectNextWaiting()
        XCTAssertEqual(store.selectedSessionId, ids[0])
        store.selectNextWaiting() // only one waiting: stays put
        XCTAssertEqual(store.selectedSessionId, ids[0])
    }

    func testClosingSelectedSessionSelectsNeighbour() throws {
        let p = try addProjects(["alpha"])[0]
        for _ in 0..<3 { try store.createSession(projectId: p, model: nil, prompt: nil) }
        let ids = store.orderedSessions.map(\.id)
        store.selectedSessionId = ids[1]
        store.closeSession(ids[1]!)
        XCTAssertEqual(store.selectedSessionId, ids[2])
        store.closeSession(ids[2]!)
        XCTAssertEqual(store.selectedSessionId, ids[0])
    }

    func testSessionsSurviveStoreRestart() throws {
        let p = try addProjects(["alpha"])[0]
        try store.createSession(projectId: p, model: "haiku", prompt: nil)
        let before = store.sessions
        let restarted = makeIsolatedStore(db: db)
        XCTAssertEqual(restarted.sessions.map(\.claudeSessionId), before.map(\.claudeSessionId))
        XCTAssertEqual(restarted.selectedSessionId, before.first?.id)
    }
}
