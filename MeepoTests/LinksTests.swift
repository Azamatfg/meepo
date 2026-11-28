import GRDB
import SwiftUI
import XCTest
@testable import Meepo

/// Linked projects (2026-11-28): a backend and its app know each other's contract files, and a change to one is
/// offered to the other — a note to a session working there, else a task.
@MainActor
final class LinksTests: XCTestCase {
    func testContractGlobs() {
        XCTAssertTrue(Links.matches("api/openapi.yaml", "api/openapi.yaml"))
        XCTAssertTrue(Links.matches("proto/v1/user.proto", "proto/**"))
        XCTAssertTrue(Links.matches("src/api/client.ts", "src/api/"), "a folder takes what's below it")
        XCTAssertTrue(Links.matches("src/api/client.ts", "src/api"))
        XCTAssertTrue(Links.matches("a.proto", "**/*.proto"))
        XCTAssertFalse(Links.matches("proto/v1/user.proto", "proto/*.proto"), "* stays within one folder")
        XCTAssertFalse(Links.matches("src/apiary.ts", "src/api"), "a folder name isn't a prefix of a file name")
        XCTAssertFalse(Links.matches("README.md", "api/openapi.yaml"))
    }

    func testLikelyContractsAreSuggested() {
        let files = ["api/openapi.yaml", "proto/user.proto", "proto/order.proto", "schema.graphql", "src/main.go", "docs/swagger.json"]
        XCTAssertEqual(Links.suggestions(files), ["api/openapi.yaml", "proto/*.proto", "schema.graphql", "docs/swagger.json"])
    }

    private func setUpPair() throws -> (AppStore, backend: Project, app: Project) {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        for _ in 0..<3 { try store.addProject(at: try makeTempRepo()) }
        store.setLinks(store.projects[0].id!, linked: [store.projects[1].id!], contracts: ["api/openapi.yaml", " ", "proto/**"])
        return (store, store.projects[0], store.projects[1])
    }

    func testALinkIsKeptOnBothSides() throws {
        let (store, backend, app) = try setUpPair()
        XCTAssertEqual(store.linkedProjects(of: app.id!).map(\.id), [backend.id], "the app sees the backend too")
        XCTAssertEqual(backend.contractPaths, ["api/openapi.yaml", "proto/**"], "blank lines dropped")
        XCTAssertEqual(store.linkedProjects(of: store.projects[2].id!), [], "an unlinked project")
        store.setLinks(backend.id!, linked: [], contracts: [])
        XCTAssertEqual(store.linkedProjects(of: app.id!), [], "unlinked on the other side as well")
    }

    func testASessionIsToldItsLinksOnce() throws {
        let (store, backend, app) = try setUpPair()
        try store.createSession(projectId: app.id!, model: nil, prompt: nil)
        let id = store.selectedSessionId!
        let prompt = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"x","prompt":"hi"}"#.utf8)
        let note = try XCTUnwrap(store.hookReply(sessionId: id, body: prompt))
        XCTAssertTrue(note.contains("\(backend.name) at \(backend.path)"), note)
        XCTAssertTrue(note.contains("depends on its contract files api/openapi.yaml, proto/**"), note)
        XCTAssertNil(store.hookReply(sessionId: id, body: prompt), "once per session")
    }

    func testAContractChangeIsOfferedAndGoesToASessionOrATask() throws {
        let (store, backend, app) = try setUpPair()
        try store.createSession(projectId: app.id!, model: nil, prompt: nil)
        let appSession = store.selectedSessionId!
        try store.createSession(projectId: backend.id!, model: nil, prompt: nil)
        let backendSession = store.selectedSessionId!
        store.runningSessionIds = [appSession, backendSession]
        store.modSessionIds = [appSession]
        let claudeId = store.sessions.first { $0.id == backendSession }!.claudeSessionId

        func turn(editing file: String) {
            store.handleHookEvent(HookPayload(event: "UserPromptSubmit", claudeSessionId: claudeId, prompt: "go"), sessionId: backendSession)
            store.handleHookEvent(HookPayload(event: "PostToolUse", claudeSessionId: claudeId, toolName: "Edit", toolTarget: "\(backend.path)/\(file)"),
                                  sessionId: backendSession)
            store.handleHookEvent(HookPayload(event: "Stop", claudeSessionId: claudeId), sessionId: backendSession)
        }
        turn(editing: "src/main.go")
        XCTAssertNil(store.confirmation, "not a contract file: nothing to tell")

        turn(editing: "api/openapi.yaml")
        let offer = try XCTUnwrap(store.confirmation)
        XCTAssertTrue(offer.message?.contains("api/openapi.yaml") == true)
        XCTAssertEqual(store.request("/inbox", appSession), [], "nothing goes out before the ok")
        offer.perform()
        let notes = store.request("/inbox", appSession)
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].contains("\(backend.name) changed its contract: api/openapi.yaml"), "\(notes)")
        XCTAssertFalse(store.tasks.contains { $0.projectId == app.id }, "a working session got it: no task")

        store.runningSessionIds = [backendSession] // nobody works in the app now
        store.confirmation = nil
        turn(editing: "proto/v1/user.proto")
        try XCTUnwrap(store.confirmation).perform()
        XCTAssertEqual(store.tasks.filter { $0.projectId == app.id }.map(\.text), ["Follow \(backend.name)'s contract change: proto/v1/user.proto"])
    }
}

private extension AppStore {
    /// The notes the mod would pick up for the session.
    func request(_ path: String, _ sessionId: Int64) -> [String] {
        let reply = modRequest(path, sessionId: sessionId, body: Data("{}".utf8)) ?? "{}"
        return (try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])?["notes"] as? [String] ?? []
    }
}

/// The Linked Projects sheet as a picture (MEEPO_SNAPSHOT_DIR).
@MainActor
final class LinkedProjectsPictureTests: XCTestCase {
    func testSheetPicture() async throws {
        let path = ProcessInfo.processInfo.environment["MEEPO_SNAPSHOT_DIR"]
        try XCTSkipIf(path == nil, "pictures only on request")
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        let repo = try makeTempRepo()
        for file in ["api/openapi.yaml", "proto/a.proto", "proto/b.proto"] {
            let url = repo.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }
        try git(["add", "."], in: repo)
        XCTAssertEqual(Links.suggestions((GitService.output(["ls-files"], in: repo.path) ?? "").split(separator: "\n").map(String.init)),
                       ["api/openapi.yaml", "proto/*.proto"])
        try store.addProject(at: repo)
        for _ in 0..<2 { try store.addProject(at: try makeTempRepo()) }
        let backend = try XCTUnwrap(store.projects.first { $0.path == repo.path }) // projects are sorted by name
        let app = try XCTUnwrap(store.projects.first { $0.id != backend.id })
        store.setLinks(backend.id!, linked: [app.id!], contracts: ["api/openapi.yaml"])
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 500, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: LinkedProjectsSheet(project: store.projects.first { $0.id == backend.id }!).environment(store))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .seconds(1.5))
        let view = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path!).appending(path: "linked.png"))
    }
}
