import GRDB
import XCTest
@testable import Meepo

/// Sessions outside meepo: `claude agents --json`, what's shown, and what Open here / Continue here do.
final class ClaudeAgentsParseTests: XCTestCase {
    func testBothKindsParseAndUnknownsAreKept() throws {
        let json = #"""
        [{"id":"db3711d8","cwd":"/Users/a/taxi","kind":"background","startedAt":1789454354676,
          "sessionId":"db3711d8-5c2c-4a38-8476-79696e02242d","name":"SIP stats","state":"blocked","newField":{"x":1}},
         {"pid":3180,"cwd":"/Users/a/meepo","kind":"interactive","startedAt":1790346015878,
          "sessionId":"65365cd3-45d6-4f5b-933e-64f0dfc81c13","name":"meepo-15","status":"busy"},
         {"id":"77","kind":"remote","state":"teleporting"},
         {"id":42,"kind":"background","state":3},
         {"cwd":"/nothing/to/call/it/by"},
         "not an object"]
        """#
        let agents = ClaudeAgents.parse(Data(json.utf8))
        XCTAssertEqual(agents.map(\.id), ["db3711d8", "65365cd3-45d6-4f5b-933e-64f0dfc81c13", "77", "42"])

        let background = agents[0]
        XCTAssertTrue(background.isBackground)
        XCTAssertEqual(background.sessionId, "db3711d8-5c2c-4a38-8476-79696e02242d")
        XCTAssertEqual(background.state, "blocked")
        XCTAssertEqual(background.startedAt, Date(timeIntervalSince1970: 1_789_454_354.676))
        XCTAssertEqual(background.place, "background")

        let interactive = agents[1]
        XCTAssertTrue(interactive.isInteractive)
        XCTAssertEqual(interactive.pid, 3180)
        XCTAssertEqual(interactive.state, "busy", "an interactive session's `status` is its state")
        XCTAssertEqual(interactive.look.text, "Working")
        XCTAssertEqual(interactive.place, "in another window", "no host app found: said plainly, not left blank")

        XCTAssertEqual(agents[2].kind, "remote")
        XCTAssertEqual(agents[2].look.text, "Teleporting", "an unknown state is shown as its own word")
        XCTAssertEqual(agents[3].state, "3", "a number where text was expected is kept as text")
        XCTAssertTrue(ClaudeAgents.parse(Data("claude: unknown command agents".utf8)).isEmpty)
    }

    func testMeeposOwnSessionsAreLeftOut() {
        var inside = agent("inside", kind: "interactive", sessionId: "c-after-clear")
        inside.isInsideMeepo = true // /clear gave it an id meepo doesn't know; its parent is meepo
        let own = agent("own", kind: "background", sessionId: "s-own")
        let other = agent("other", kind: "interactive", sessionId: "s-other")
        XCTAssertEqual(ClaudeAgents.others([inside, own, other], ownSessionIds: ["s-own"]).map(\.id), ["other"])
    }

    func testHostAppIsNamedPlainly() {
        func host(_ paths: String...) -> String? { ClaudeAgents.hostApp(ancestorPaths: paths) }
        XCTAssertEqual(host("/bin/zsh", "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper",
                            "/Applications/Visual Studio Code.app/Contents/MacOS/Code"), "VS Code",
                       "the outermost app, not its helper")
        XCTAssertEqual(host("/bin/zsh", "/usr/bin/login", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"), "Terminal")
        XCTAssertEqual(host("/bin/zsh", "/Applications/iTerm.app/Contents/MacOS/iTerm2"), "iTerm")
        XCTAssertEqual(host("/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)"), "Cursor")
        XCTAssertEqual(host("/Applications/Warp.app/Contents/MacOS/stable"), "Warp")
        XCTAssertEqual(host("/Applications/Ghostty.app/Contents/MacOS/ghostty"), "Ghostty")
        XCTAssertNil(host("/bin/zsh", "/opt/homebrew/bin/tmux"), "tmux under launchd: no app to name")
    }

    func testTerminalOutputBecomesPlainText() {
        let raw = "\u{1B}]0;claude\u{07}\u{1B}[1m\u{1B}[38;5;166m✻\u{1B}[0m Done\r\n\u{1B}[2K\u{1B}[1Gnext\u{1B}(B"
        XCTAssertEqual(ClaudeAgents.plainText(raw), "✻ Done\nnext")
    }

    func testAttachLaunchesAttachNotANewClaude() {
        XCTAssertEqual(ClaudeLauncher.attachArguments(agentId: "db3711d8"), ["attach", "db3711d8"])
    }
}

func agent(_ id: String, kind: String, sessionId: String? = nil, cwd: String? = nil, state: String? = nil) -> ClaudeAgents.Agent {
    ClaudeAgents.Agent(id: id, kind: kind, sessionId: sessionId, cwd: cwd, name: id, state: state)
}

@MainActor
final class ElsewhereStoreTests: XCTestCase {
    private var store: AppStore!
    private var home: URL!

    override func setUp() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        home = FileManager.default.temporaryDirectory.appending(path: "ew-\(UUID().uuidString)")
        store = AppStore(db: db, bridge: BridgeInstaller(settingsURL: home.appending(path: "s.json"), meepoHome: home),
                         usageRoot: home, defaults: UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!)
    }

    func testContinueHereIsOfferedOnceTheOtherWindowEndedIt() throws {
        let repo = try makeTempRepo()
        let vscode = agent("5e0b", kind: "interactive", sessionId: "5e0b7c9d-2f14-4a88-b6d3-91c0e4a7f252", cwd: repo.path, state: "busy")
        let start = Date.now
        store.applyAgents([vscode], now: start)
        XCTAssertEqual(store.elsewhere.count, 1)
        XCTAssertFalse(store.elsewhere[0].canContinueHere, "still running in VS Code: one conversation, one place")
        try store.continueHere(store.elsewhere[0])
        XCTAssertTrue(store.sessions.isEmpty, "nothing taken over while it runs there")

        store.applyAgents([], now: start + 60) // closed in VS Code
        let ended = try XCTUnwrap(store.elsewhere.first)
        XCTAssertEqual(ended.endedAt, start + 60)
        XCTAssertTrue(ended.canContinueHere)
        XCTAssertEqual(ended.look.text, "Ended")
        store.applyAgents([], now: start + 3600)
        XCTAssertEqual(store.elsewhere.first?.endedAt, start + 60, "ended once, not every poll")

        XCTAssertTrue(store.isNewProject(ended))
        try store.continueHere(ended)
        let session = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(session.claudeSessionId, vscode.sessionId, "its own conversation, resumed")
        XCTAssertNil(session.agentId)
        XCTAssertEqual(store.projects.map(\.path), [repo.path], "its folder became a project")
        XCTAssertNil(store.attachId(for: session))
        store.applyAgents([], now: start + 3700)
        XCTAssertTrue(store.elsewhere.isEmpty, "now it's meepo's own")
    }

    func testEndedOnesAreKeptADayAndComeBackToLife() {
        let a = agent("a", kind: "interactive", sessionId: "s-a", state: "idle")
        let start = Date.now
        store.applyAgents([a], now: start)
        store.applyAgents([], now: start + 10)
        store.applyAgents([a], now: start + 20)
        XCTAssertNil(store.elsewhere.first?.endedAt, "opened again in its window: live again")
        store.applyAgents([], now: start + 30)
        store.applyAgents([], now: start + 30 + 25 * 3600)
        XCTAssertTrue(store.elsewhere.isEmpty, "gone after a day")
        let background = agent("bg", kind: "background", sessionId: "s-bg", state: "working")
        store.applyAgents([background], now: start)
        store.applyAgents([], now: start + 10)
        XCTAssertTrue(store.elsewhere.isEmpty, "a background agent that's gone isn't offered anything")
    }

    func testBlockedBackgroundAgentNeedsYou() {
        XCTAssertEqual(store.waitingCount, 0)
        store.applyAgents([agent("w", kind: "background", sessionId: "s-w", state: "working"),
                           agent("i", kind: "interactive", sessionId: "s-i", state: "idle")])
        XCTAssertEqual(store.waitingCount, 0)
        store.applyAgents([agent("b", kind: "background", sessionId: "s-b", state: "blocked")])
        XCTAssertEqual(store.waitingCount, 1, "it waits for the user: \"1 needs you\"")
        XCTAssertEqual(store.elsewhere.first?.look.text, "Waiting for you")
    }

    func testOpenHereAttachesWhileItRunsAndResumesAfter() throws {
        let repo = try makeTempRepo()
        let sub = repo.appending(path: "backend")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let background = agent("db3711d8", kind: "background", sessionId: "db3711d8-5c2c-4a38-8476-79696e02242d",
                               cwd: sub.path, state: "blocked")
        store.applyAgents([background])
        try store.openHere(store.elsewhere[0])

        let session = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(session.agentId, "db3711d8")
        XCTAssertEqual(session.claudeSessionId, background.sessionId, "its hook events find this tab")
        XCTAssertEqual(session.folder, sub.path, "runs where it was started, not at the repo root")
        XCTAssertEqual(store.projects.map(\.path), [repo.path])
        XCTAssertEqual(store.selectedSessionId, session.id)
        XCTAssertEqual(store.attachId(for: session), "db3711d8", "still running: attach, don't start a second claude")
        XCTAssertTrue(store.elsewhere.isEmpty, "it's meepo's now")
        XCTAssertEqual(store.waitingCount, 0, "counted once, as the tab, not also as elsewhere")

        let marker = home.appending(path: "attached/\(background.sessionId!)")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), String(session.id!))

        store.applyAgents([]) // stopped (or meepo relaunched after it finished)
        XCTAssertNil(store.attachId(for: session), "not running: its conversation resumes instead")

        store.closeSession(session.id!)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appending(path: "attached").path),
                       "nothing attached: the folder goes, so other sessions' hooks exit at once")
    }

    /// `/clear` inside an agent open here: the list shows the same agent with a new session id. It stays this
    /// tab's (not also listed as elsewhere), and the marker follows it so its hook events keep finding the tab.
    func testClearInAnAttachedAgentFollowsItsNewSessionId() throws {
        let repo = try makeTempRepo()
        let before = agent("db3711d8", kind: "background", sessionId: "aaaa-1111", cwd: repo.path, state: "idle")
        store.applyAgents([before])
        try store.openHere(store.elsewhere[0])
        var after = before
        after.sessionId = "bbbb-2222"
        store.applyAgents([after])
        XCTAssertTrue(store.elsewhere.isEmpty, "the tab's own agent, not a second entry")
        XCTAssertEqual(store.sessions.first?.claudeSessionId, "bbbb-2222")
        let dir = home.appending(path: "attached")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["bbbb-2222"])
        XCTAssertEqual(try String(contentsOf: dir.appending(path: "bbbb-2222"), encoding: .utf8), String(store.sessions[0].id!))
    }

    /// A marker left over (a tab closed while meepo was off, an agent that ended) goes at the first list.
    func testStaleMarkersGoAtTheFirstList() throws {
        let repo = try makeTempRepo()
        try store.addProject(at: repo)
        try store.createSession(projectId: store.projects[0].id!, model: nil, prompt: nil, resuming: "live-1",
                                name: nil, agentId: "live", folder: nil)
        try store.createSession(projectId: store.projects[0].id!, model: nil, prompt: nil, resuming: "done-1",
                                name: nil, agentId: "done", folder: nil)
        let dir = home.appending(path: "attached")
        try Data("999".utf8).write(to: dir.appending(path: "gone-1")) // its tab doesn't exist
        store.applyAgents([agent("live", kind: "background", sessionId: "live-1", state: "idle")])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["live-1"])

        store.closeSession(store.sessions.first { $0.agentId == "live" }!.id!)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    /// Before any `claude agents` came back (it failed, or timed out) a tab on an agent attaches: resuming would run
    /// a second claude on a conversation the agent may still be running.
    func testUnknownListAttachesRatherThanResumes() throws {
        try store.addProject(at: try makeTempRepo())
        try store.createSession(projectId: store.projects[0].id!, model: nil, prompt: nil, resuming: "s-1",
                                name: nil, agentId: "db3711d8", folder: nil)
        let session = store.sessions[0]
        XCTAssertEqual(store.attachId(for: session), "db3711d8")
        store.applyAgents([])
        XCTAssertNil(store.attachId(for: session), "listed and not running: resume")
    }

    /// Listed once as gone isn't proof: while its process still runs, Continue here takes nothing over.
    func testContinueHereWaitsForTheProcessToEnd() throws {
        let repo = try makeTempRepo()
        var other = agent("o", kind: "interactive", sessionId: "s-o", cwd: repo.path, state: "busy")
        other.pid = getpid() // alive
        let start = Date.now
        store.applyAgents([other], now: start)
        store.applyAgents([], now: start + 15) // one listing missed it
        XCTAssertNotNil(store.elsewhere.first?.endedAt)
        XCTAssertFalse(store.elsewhere[0].canContinueHere)
        try store.continueHere(store.elsewhere[0])
        XCTAssertTrue(store.sessions.isEmpty)
    }

    /// An older refresh that comes back after a newer one is dropped, not shown over it.
    func testASlowerOlderRefreshIsDropped() async {
        let stale = agent("i", kind: "interactive", sessionId: "s-i", state: "busy")
        let store = store!
        let slow = Task { await store.refreshElsewhere { usleep(300_000); return [stale] } }
        try? await Task.sleep(for: .milliseconds(50))
        await store.refreshElsewhere { [] }
        await slow.value
        XCTAssertTrue(store.elsewhere.isEmpty)
    }
}

/// The real bridge script: a background agent's hook events (no MEEPO_SESSION_ID) reach its meepo tab.
@MainActor
final class AttachedBridgeTests: XCTestCase {
    func testAttachedAgentEventsReachItsTab() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "ab-\(UUID().uuidString)")
        let installer = BridgeInstaller(settingsURL: home.appending(path: "settings.json"), meepoHome: home.appending(path: ".meepo"))
        try installer.writeScript()
        let token = try MeepoHome.token(in: home.appending(path: ".meepo"))
        let port = UInt16.random(in: 49_000...59_000)
        var received: [(Int64, String)] = []
        let server = EventServer(token: token) { id, body in received.append((id, String(decoding: body, as: UTF8.self))) }
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(200))

        func fire(_ sessionId: String) async throws {
            try await Task.detached {
                let process = Process()
                process.executableURL = URL(filePath: "/bin/bash")
                process.arguments = [installer.scriptURL.path]
                process.environment = ["HOME": home.path, "MEEPO_PORT": String(port), "PATH": "/usr/bin:/bin"]
                let input = Pipe()
                process.standardInput = input
                process.standardOutput = FileHandle.nullDevice
                try process.run()
                input.fileHandleForWriting.write(Data(#"{"session_id":"\#(sessionId)","hook_event_name":"Stop"}"#.utf8))
                try input.fileHandleForWriting.close()
                process.waitForExit()
            }.value
            try await Task.sleep(for: .milliseconds(200))
        }

        try await fire("aaaa-1111") // nothing attached: no folder, exits at once
        XCTAssertTrue(received.isEmpty)
        try FileManager.default.createDirectory(at: installer.attachedURL, withIntermediateDirectories: true)
        try Data("9".utf8).write(to: installer.attachedURL.appending(path: "bbbb-2222"))
        try await fire("aaaa-1111") // another session, not attached
        XCTAssertTrue(received.isEmpty)
        try await fire("bbbb-2222")
        XCTAssertEqual(received.map(\.0), [9])
        XCTAssertEqual(received.first?.1, #"{"session_id":"bbbb-2222","hook_event_name":"Stop"}"#, "the event itself, unchanged")
    }
}
