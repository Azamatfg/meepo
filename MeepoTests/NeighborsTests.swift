import GRDB
import XCTest
@testable import Meepo

/// Parallel sessions without chaos (2026-11-29): sessions in one folder know each other, and a file one of them
/// edited asks before another edits it.
@MainActor
final class NeighborsTests: XCTestCase {
    private func store() throws -> (AppStore, Project) {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        try store.addProject(at: try makeTempRepo())
        return (store, store.projects[0])
    }

    private func edit(_ file: String, by sessionId: Int64, in store: AppStore, ago: TimeInterval = 60) throws {
        try store.db.write { db in
            var event = HookEvent(sessionId: sessionId, name: "PostToolUse", summary: "Edit: \(file)", isFailure: false,
                                  createdAt: .now.addingTimeInterval(-ago))
            try event.insert(db)
        }
    }

    private func preToolUse(_ file: String) -> Data {
        Data(#"{"hook_event_name":"PreToolUse","session_id":"x","tool_name":"Edit","tool_input":{"file_path":"\#(file)"}}"#.utf8)
    }

    private let prompt = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"x","prompt":"hi"}"#.utf8)

    func testAFileANeighborEditedAsksAndAnotherFileDoesNot() throws {
        let (store, project) = try store()
        try store.createSession(projectId: project.id!, model: nil, prompt: nil, name: "fix login")
        let a = store.selectedSessionId!
        try store.createSession(projectId: project.id!, model: nil, prompt: nil, name: "add search")
        let b = store.selectedSessionId!
        store.runningSessionIds = [a, b]
        try edit("\(project.path)/Login.swift", by: a, in: store)
        try edit("\(project.path)/Old.swift", by: a, in: store, ago: 3 * 3600) // past the claim window

        let ask = try XCTUnwrap(store.hookReply(sessionId: b, body: preToolUse("\(project.path)/Login.swift")))
        XCTAssertTrue(ask.contains(#""permissionDecision":"ask""#))
        XCTAssertTrue(ask.contains("fix login"))
        XCTAssertNil(store.hookReply(sessionId: b, body: preToolUse("\(project.path)/Search.swift")), "nobody's file")
        XCTAssertNil(store.hookReply(sessionId: b, body: preToolUse("\(project.path)/Old.swift")), "edited too long ago")
        XCTAssertNil(store.hookReply(sessionId: a, body: preToolUse("\(project.path)/Login.swift")), "its own file")

        store.runningSessionIds = [b] // the neighbor exited: its files are free
        XCTAssertNil(store.hookReply(sessionId: b, body: preToolUse("\(project.path)/Login.swift")))
    }

    func testAWorktreeSessionIsNoNeighbor() throws {
        let (store, project) = try store()
        try store.createSession(projectId: project.id!, model: nil, prompt: nil)
        let a = store.selectedSessionId!
        try store.createSession(projectId: project.id!, model: nil, prompt: nil, worktree: "feature")
        let b = store.selectedSessionId!
        store.runningSessionIds = [a, b]
        XCTAssertEqual(store.neighborSessions(of: a), [])
        XCTAssertEqual(store.neighborSessions(of: b), [])
    }

    func testANewTabInABusyFolderOffersAWorktree() throws {
        let (store, project) = try store()
        try store.createSession(projectId: project.id!, model: nil, prompt: nil)
        store.newTab() // the first session isn't running: no one to collide with
        XCTAssertNil(store.confirmation)
        XCTAssertEqual(store.sessions.count, 2)

        store.runningSessionIds = Set(store.sessions.compactMap(\.id))
        store.newTab()
        let offer = try XCTUnwrap(store.confirmation, "a live session works in this folder")
        XCTAssertEqual(store.sessions.count, 2, "nothing starts before the choice")
        offer.perform()
        XCTAssertEqual(store.selectedSession?.worktreeName, "tab-2")
    }

    func testClaudeIsToldItsNeighborsOnceUntilTheyChange() throws {
        let (store, project) = try store()
        try store.createSession(projectId: project.id!, model: nil, prompt: nil, name: "fix login")
        let a = store.selectedSessionId!
        try store.createSession(projectId: project.id!, model: nil, prompt: nil)
        let b = store.selectedSessionId!
        store.runningSessionIds = [a, b]
        try edit("\(project.path)/Login.swift", by: a, in: store)

        let note = try XCTUnwrap(store.hookReply(sessionId: b, body: prompt))
        XCTAssertTrue(note.contains("\"fix login\": edited Login.swift"), note)
        XCTAssertNil(store.hookReply(sessionId: b, body: prompt), "the same neighbors aren't repeated")
        try edit("\(project.path)/Auth.swift", by: a, in: store)
        XCTAssertTrue(try XCTUnwrap(store.hookReply(sessionId: b, body: prompt)).contains("Auth.swift"))
    }
}
