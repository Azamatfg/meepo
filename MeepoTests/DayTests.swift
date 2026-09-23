import GRDB
import XCTest
@testable import Meepo

final class AgentTodoParsingTests: XCTestCase {
    func testTodosFromEditsInCodeFilesOnly() throws {
        let edit = #"{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"/a/api.go","old_string":"x","new_string":"x := 1\n// TODO: handle timeout\nlog(\"TODOs are fine in strings\")"}}"#
        XCTAssertEqual(HookPayload(json: Data(edit.utf8))?.todoLines, ["// TODO: handle timeout"])

        let multi = #"{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"MultiEdit","tool_input":{"file_path":"/a/b.swift","edits":[{"new_string":"// FIXME later"},{"new_string":"let x = 1 // HACK"}]}}"#
        XCTAssertEqual(HookPayload(json: Data(multi.utf8))?.todoLines, ["// FIXME later", "let x = 1 // HACK"])

        let docs = #"{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"/a/PLAN.md","content":"- [ ] TODO: write docs"}}"#
        XCTAssertEqual(HookPayload(json: Data(docs.utf8))?.todoLines, []) // task lists in docs aren't code debt
    }
}

@MainActor
final class MorningEveningTests: XCTestCase {
    private var db: DatabaseQueue!
    private var store: AppStore!
    private var app: Project!
    private var api: Project!

    override func setUp() async throws {
        db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        store = makeIsolatedStore(db: db)
        for name in ["webapp", "billing-api"] {
            let repo = try makeTempRepo()
            let named = repo.deletingLastPathComponent().appending(path: name + "-" + UUID().uuidString.prefix(4))
            try FileManager.default.moveItem(at: repo, to: named)
            try git(["commit", "-q", "--allow-empty", "-m", "init \(name)"], in: named)
            try store.addProject(at: named)
        }
        app = store.projects.first { $0.name.hasPrefix("webapp") }
        api = store.projects.first { $0.name.hasPrefix("billing-api") }
    }

    func testPastedListBecomesTasksWithGuessedProjects() {
        XCTAssertEqual(AppStore.taskLines("- fix login\n2) add export\n\n• [ ] tidy up"), ["fix login", "add export", "tidy up"])
        // Project names in these tests carry a random suffix; a plain word matches only the exact name.
        let exact = store.projects.first { $0.id == app.id }!
        XCTAssertNil(store.guessProject(for: "fix the webapp login")) // "webapp" ≠ "webapp-1a2b"
        XCTAssertEqual(store.guessProject(for: "fix \(exact.name) login"), exact.id)
        XCTAssertNil(store.guessProject(for: "general cleanup"))
    }

    /// SPEC module 7 "done when": the evening list becomes launched sessions with one button the next morning.
    func testEveningListStartsTomorrowsSessions() throws {
        var login = try XCTUnwrap(store.addTask("Fix login redirect", projectId: app.id))
        login.note = "Happens only on Safari"
        login.attachments = ["/tmp/shot.png", "https://issue/42"]
        store.updateTask(login)
        let export = try XCTUnwrap(store.addTask("Add CSV export", projectId: app.id))
        let refunds = try XCTUnwrap(store.addTask("Refund webhook", projectId: api.id))
        var done = try XCTUnwrap(store.addTask("Already shipped", projectId: api.id))
        done.isDone = true
        store.updateTask(done)

        // Next morning: the open ones are what the Morning sheet preselects.
        let open = store.tasks.filter { !$0.isDone }.compactMap(\.id)
        XCTAssertEqual(Set(open), [login.id!, export.id!, refunds.id!])
        try store.launchMorning(open)

        XCTAssertEqual(store.sessions.count, 3)
        let appSessions = store.sessions.filter { $0.projectId == app.id }
        XCTAssertEqual(appSessions.filter { $0.worktreeName == nil }.count, 1)  // first task in the main checkout
        XCTAssertEqual(appSessions.filter { $0.worktreeName != nil }.count, 1)  // second one in its own worktree
        let prompt = store.initialPrompts[store.tasks.first { $0.id == login.id }!.sessionId!]!
        XCTAssertTrue(prompt.hasPrefix("Fix login redirect"))
        XCTAssertTrue(prompt.contains("Happens only on Safari"))
        XCTAssertTrue(prompt.contains("- /tmp/shot.png") && prompt.contains("- https://issue/42"))
    }

    func testDaySummaryCollectsCommitsStagesTodosNextSteps() throws {
        try store.createSession(projectId: app.id!, model: nil, prompt: nil)
        let session = store.sessions[0]
        func send(_ payload: HookPayload) { store.handleHookEvent(payload, sessionId: session.id!) }
        send(HookPayload(event: "UserPromptExpansion", claudeSessionId: session.claudeSessionId, prompt: "/plan x", commandName: "plan"))
        send(try XCTUnwrap(HookPayload(json: Data(#"{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"/w/a.ts","new_string":"// TODO: retry"}}"#.utf8))))
        send(HookPayload(event: "UserPromptExpansion", claudeSessionId: session.claudeSessionId, prompt: "/sync", commandName: "sync"))
        send(HookPayload(event: "Stop", claudeSessionId: session.claudeSessionId, lastAssistantMessage: "Next: wire the API"))
        store.addTask("Polish UI", projectId: app.id)

        let day = try XCTUnwrap(store.daySummary().first { $0.project.id == app.id })
        XCTAssertEqual(day.stages, ["plan", "sync"])
        XCTAssertEqual(day.todos.map(\.line), ["// TODO: retry"])
        XCTAssertEqual(day.nextSteps, "Next: wire the API")
        XCTAssertTrue(day.commits.contains { $0.hasSuffix("init \(app.name.prefix(6))") || $0.contains("init webapp") })
        XCTAssertEqual(day.openTasks, ["Polish UI"])
        let text = AppStore.dayText([day])
        XCTAssertTrue(text.contains("Stages: plan → sync"))
        XCTAssertTrue(text.contains("☐ Polish UI"))
    }
}
