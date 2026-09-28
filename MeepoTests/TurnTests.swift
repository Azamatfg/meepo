import GRDB
import XCTest
@testable import Meepo

/// Whether Claude is in a turn, and whether a prompt is on screen: what a button's Enter and a tab's × go by.
@MainActor
final class TurnTests: XCTestCase {
    private var store: AppStore!
    private var session: Session { store.sessions[0] }
    private var sid: Int64 { session.id! }

    override func setUp() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        store = makeIsolatedStore(db: db)
        try store.addProject(at: try makeTempRepo())
        try store.createSession(projectId: store.projects[0].id!, model: nil, prompt: nil)
    }

    private func send(_ event: String, prompt: String? = nil, tool: String? = nil, target: String? = nil, agent: String? = nil,
                      backgroundTasks: Int = 0) {
        var payload = HookPayload(event: event, claudeSessionId: session.claudeSessionId, prompt: prompt, toolName: tool, toolTarget: target)
        payload.agentId = agent
        payload.backgroundTasks = backgroundTasks
        store.handleHookEvent(payload, sessionId: sid)
    }

    /// Background helpers keep working while one agent waits on a permission: their steps must not make the prompt
    /// look answered, or a button's Enter would say yes to it.
    func testAnotherAgentsStepDoesntCloseAPrompt() {
        send("PermissionRequest", tool: "Bash", target: "rm x", agent: "a")
        send("PostToolUse", tool: "Read", target: "/r.swift", agent: "b")
        XCTAssertEqual(session.status, .thinking, "the helper's step reads as work")
        XCTAssertFalse(store.type("/qa\r", into: sid), "a's prompt is still on screen")
        send("PostToolUse", tool: "Bash", target: "rm x", agent: "a")
        XCTAssertTrue(store.type("/qa\r", into: sid), "a's call ran: its prompt was answered")

        send("PermissionRequest", tool: "Bash", target: "rm y")
        send("PostToolUse", tool: "Read", target: "/r.swift", agent: "b")
        XCTAssertFalse(store.type("/qa\r", into: sid), "the main conversation still asks")
        send("PreToolUse", tool: "Grep", target: "y")
        XCTAssertFalse(store.type("/qa\r", into: sid), "a parallel call from the same message: the prompt is still up")
        send("PostToolUse", tool: "Bash", target: "rm y")
        XCTAssertTrue(store.type("/qa\r", into: sid), "the asked call ran")

        send("PermissionRequest", tool: "WebFetch", target: "https://a.b", agent: "a")
        send("Stop", backgroundTasks: 1)
        XCTAssertFalse(store.type("/qa\r", into: sid), "the main turn ended, the helper still asks")
        send("UserPromptSubmit", prompt: "<task-notification>\n<summary>Agent \"b\" finished</summary>\n</task-notification>")
        send("StopFailure")
        XCTAssertFalse(store.type("/qa\r", into: sid), "Claude Code's own turn and an API error end the main turn, not a's prompt")
        send("Stop")
        XCTAssertTrue(store.type("/qa\r", into: sid), "nothing left running: nobody asks")
    }

    /// No hook says the user answered No or pressed Esc, so the wait can't end by itself: the user can send anyway,
    /// and what waits on the sending (RELAY's arming) happens only then.
    func testAPromptLeftWithoutAHookCanBeSentAnyway() throws {
        send("PermissionRequest", tool: "Bash", target: "rm -rf build")
        XCTAssertFalse(store.type("/qa\r", into: sid))
        let question = try XCTUnwrap(store.confirmation)
        XCTAssertEqual(question.action, "OK", "Enter on the box doesn't send: it may be meant for the prompt")
        XCTAssertNotNil(question.alternative)
        question.alternative?.perform() // no terminal in tests: nothing to type into, and nothing breaks

        store.relay(sid)
        XCTAssertFalse(store.relayingSessionIds.contains(sid), "not typed: RELAY isn't armed")
        store.confirmation?.alternative?.perform()
        XCTAssertTrue(store.relayingSessionIds.contains(sid), "sent anyway: armed")
    }

    /// A tab's × asks first only mid-turn: working, or a prompt on screen. A finished turn closes right away.
    func testMidTurnFollowsTheTurn() {
        XCTAssertFalse(store.isMidTurn(sid), "fresh")
        send("UserPromptSubmit")
        XCTAssertTrue(store.isMidTurn(sid), "working")
        send("PermissionRequest", tool: "Bash", target: "ls")
        XCTAssertTrue(store.isMidTurn(sid), "waiting on the user's answer inside the turn")
        send("PostToolUse", tool: "Bash", target: "ls")
        send("Stop")
        XCTAssertEqual(session.status, .waitingInput)
        XCTAssertFalse(store.isMidTurn(sid), "the turn is done: \"waiting for you\" is between turns")
        send("UserPromptSubmit")
        send("Stop", backgroundTasks: 1)
        XCTAssertTrue(store.isMidTurn(sid), "background work still running")
        send("StopFailure")
        XCTAssertFalse(store.isMidTurn(sid), "an API error ended the turn")
    }
}
