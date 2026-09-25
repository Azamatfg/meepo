import GRDB
import XCTest
@testable import Meepo

final class HookPayloadTests: XCTestCase {
    /// Shapes captured from a real claude 2.1.280 run (fields trimmed).
    func testParsesRealStopPayload() throws {
        let json = #"{"session_id":"c1644dec","transcript_path":"/x.jsonl","cwd":"/p","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"ок2","future_field":{"a":1}}"#
        let p = try XCTUnwrap(HookPayload(json: Data(json.utf8)))
        XCTAssertEqual(p.event, "Stop")
        XCTAssertEqual(p.claudeSessionId, "c1644dec")
        XCTAssertEqual(p.summary, "ок2")
        XCTAssertEqual(p.status, .waitingInput)
    }

    func testToolEventsSummariseTheirTarget() throws {
        let json = #"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm test","description":"run"}}"#
        let p = try XCTUnwrap(HookPayload(json: Data(json.utf8)))
        XCTAssertEqual(p.summary, "Bash: npm test")
        XCTAssertEqual(p.status, .waitingPermission)
    }

    func testRejectsPayloadWithoutEventOrSession() {
        XCTAssertNil(HookPayload(json: Data(#"{"session_id":"s"}"#.utf8)))
        XCTAssertNil(HookPayload(json: Data("not json".utf8)))
    }

    func testUnknownEventIsKeptButDoesNotChangeStatus() throws {
        let p = try XCTUnwrap(HookPayload(json: Data(#"{"session_id":"s","hook_event_name":"FutureEvent"}"#.utf8)))
        XCTAssertNil(p.status)
        XCTAssertFalse(p.isFailure)
    }

    func testNotificationTypesMapToWaitingStates() {
        func status(_ type: String) -> SessionStatus? {
            HookPayload(event: "Notification", claudeSessionId: "s", notificationType: type).status
        }
        XCTAssertEqual(status("permission_prompt"), .waitingPermission)
        XCTAssertEqual(status("idle_prompt"), .waitingInput)
        XCTAssertNil(status("auth_success"))
    }

    func testAttentionFiresOnceOnEnteringWaitState() {
        // PermissionRequest then Notification(permission_prompt): one notification.
        XCTAssertEqual(Attention.from(.thinking, to: .waitingPermission), .permission)
        XCTAssertNil(Attention.from(.waitingPermission, to: .waitingPermission))
        // Finished work notifies; idle_prompt on a never-used session doesn't.
        XCTAssertEqual(Attention.from(.thinking, to: .waitingInput), .done)
        XCTAssertNil(Attention.from(.idle, to: .waitingInput))
        XCTAssertEqual(Attention.from(.thinking, to: .error), .error)
        XCTAssertNil(Attention.from(.waitingInput, to: .thinking))
    }
}

final class HTTPRequestTests: XCTestCase {
    private let raw = "POST /event HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Meepo-Token: t\r\nX-Meepo-Session: 7\r\nContent-Length: 5\r\n\r\nhello"

    func testWaitsForFullBody() {
        XCTAssertNil(HTTPRequest.parse(Data(raw.dropLast(2).utf8)))
        XCTAssertNil(HTTPRequest.parse(Data("POST /event HTTP/1.1\r\nContent-Length: 5\r\n".utf8)))
        let request = HTTPRequest.parse(Data(raw.utf8))
        XCTAssertEqual(request?.body, Data("hello".utf8))
        XCTAssertEqual(request?.headers["x-meepo-session"], "7")
    }

    func testRouteChecksPathTokenAndSession() throws {
        let ok = try XCTUnwrap(HTTPRequest.parse(Data(raw.utf8)))
        XCTAssertEqual(EventServer.route(ok, token: "t").status, 204)
        XCTAssertEqual(EventServer.route(ok, token: "t").sessionId, 7)
        XCTAssertEqual(EventServer.route(ok, token: "other").status, 401)
        var wrongPath = ok
        wrongPath.path = "/"
        XCTAssertEqual(EventServer.route(wrongPath, token: "t").status, 404)
        var noSession = ok
        noSession.headers["x-meepo-session"] = nil
        XCTAssertEqual(EventServer.route(noSession, token: "t").status, 400)
    }
}

final class BridgeInstallerTests: XCTestCase {
    private var dir: URL!
    private var installer: BridgeInstaller!

    /// The user's real layout: own hooks, other settings keys.
    private let userSettings: [String: Any] = [
        "model": "opus",
        "hooks": [
            "SessionStart": [["hooks": [["type": "command", "command": "/Users/me/.claude/hooks/worktree-init.sh"]]]],
            "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "safety.sh"]]]],
        ],
    ]

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "bridge-\(UUID().uuidString)")
        installer = BridgeInstaller(settingsURL: dir.appending(path: "claude/settings.json"),
                                    meepoHome: dir.appending(path: "meepo"))
    }

    private func writeSettings(_ object: [String: Any]) throws {
        try FileManager.default.createDirectory(at: installer.settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: installer.settingsURL)
    }

    private func readSettings() throws -> NSDictionary {
        try JSONSerialization.jsonObject(with: Data(contentsOf: installer.settingsURL)) as! NSDictionary
    }

    private func bridgeCount(_ settings: NSDictionary, event: String) -> Int {
        let groups = (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
        return groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .filter { ($0["command"] as? String)?.hasSuffix("meepo-bridge.sh") == true }.count
    }

    func testInstallAddsBridgeNextToUserHooksAndKeepsOtherKeys() throws {
        try writeSettings(userSettings)
        let backup = try XCTUnwrap(try installer.install())
        let settings = try readSettings()
        for event in BridgeInstaller.events { XCTAssertEqual(bridgeCount(settings, event: event), 1, event) }
        let sessionStart = (settings["hooks"] as! [String: Any])["SessionStart"] as! [[String: Any]]
        XCTAssertEqual(sessionStart.count, 2) // user's worktree-init kept
        XCTAssertEqual(settings["model"] as? String, "opus")
        XCTAssertTrue(installer.isInstalled())
        // Backup is the untouched original.
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as? NSDictionary,
                       userSettings as NSDictionary)
    }

    func testInstallTwiceDoesNotDuplicate() throws {
        try writeSettings(userSettings)
        try installer.install()
        try installer.install()
        XCTAssertEqual(bridgeCount(try readSettings(), event: "Stop"), 1)
    }

    func testUninstallRestoresOriginalSettings() throws {
        try writeSettings(userSettings)
        try installer.install()
        try installer.uninstall()
        XCTAssertEqual(try readSettings(), userSettings as NSDictionary)
        XCTAssertFalse(installer.isInstalled())
    }

    func testUninstallKeepsUserHandlerSharingAGroupWithBridge() throws {
        let bridge = installer.scriptURL.path
        try writeSettings(["hooks": ["Stop": [["hooks": [
            ["type": "command", "command": "mine.sh"], ["type": "command", "command": bridge],
        ]]]]])
        try installer.uninstall()
        XCTAssertEqual(try readSettings(), ["hooks": ["Stop": [["hooks": [["type": "command", "command": "mine.sh"]]]]]] as NSDictionary)
    }

    func testInvalidSettingsAreLeftUntouched() throws {
        try FileManager.default.createDirectory(at: installer.settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let broken = Data("{ \"hooks\": // comment\n }".utf8)
        try broken.write(to: installer.settingsURL)
        XCTAssertThrowsError(try installer.install())
        XCTAssertEqual(try Data(contentsOf: installer.settingsURL), broken)
    }

    func testInstallCreatesMissingSettingsAndExecutableScript() throws {
        XCTAssertNil(try installer.install())
        XCTAssertTrue(installer.isInstalled())
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installer.scriptURL.path))
    }
}

/// The real bridge script, real curl, real server: what Claude Code will actually run.
@MainActor
final class BridgeEndToEndTests: XCTestCase {
    private let port: UInt16 = 47_899
    private var home: URL!
    private var server: EventServer!
    private var received: [(Int64, Data)] = []

    override func setUp() async throws {
        home = FileManager.default.temporaryDirectory.appending(path: "home-\(UUID().uuidString)")
        let installer = BridgeInstaller(settingsURL: home.appending(path: ".claude/settings.json"),
                                        meepoHome: home.appending(path: ".meepo"))
        try installer.writeScript()
        let token = try MeepoHome.token(in: home.appending(path: ".meepo"))
        server = EventServer(token: token) { [weak self] id, body in self?.received.append((id, body)) }
        try server.start(port: port)
        try await Task.sleep(for: .milliseconds(200))
    }

    override func tearDown() async throws {
        server.stop()
    }

    private func runBridge(env: [String: String], stdin: String) async throws -> Int32 {
        let script = home.appending(path: ".meepo/bin/meepo-bridge.sh").path
        let base = ["HOME": home.path, "PATH": "/usr/bin:/bin", "MEEPO_PORT": String(port)]
        return try await Task.detached {
            let p = Process()
            p.executableURL = URL(filePath: script)
            p.environment = base.merging(env) { _, new in new }
            let input = Pipe()
            p.standardInput = input
            try p.run()
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try input.fileHandleForWriting.close()
            p.waitUntilExit()
            return p.terminationStatus
        }.value
    }

    private func waitForEvents(_ count: Int) async throws {
        for _ in 0..<40 where received.count < count { try await Task.sleep(for: .milliseconds(50)) }
    }

    func testMeepoSessionEventArrivesWithItsId() async throws {
        let payload = #"{"session_id":"abc","hook_event_name":"Stop","last_assistant_message":"готово"}"#
        let status = try await runBridge(env: ["MEEPO_SESSION_ID": "42"], stdin: payload)
        XCTAssertEqual(status, 0)
        try await waitForEvents(1)
        XCTAssertEqual(received.first?.0, 42)
        XCTAssertEqual(received.first.flatMap { HookPayload(json: $0.1) }?.summary, "готово")
    }

    func testForeignSessionsAndMissingMeepoAreSilentNoOps() async throws {
        // Not started by Meepo: nothing is sent.
        let foreign = try await runBridge(env: [:], stdin: "{}")
        XCTAssertEqual(foreign, 0)
        // Meepo not listening on that port: still exit 0, claude isn't disturbed.
        let noMeepo = try await runBridge(env: ["MEEPO_SESSION_ID": "1", "MEEPO_PORT": "1"], stdin: "{}")
        XCTAssertEqual(noMeepo, 0)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(received.isEmpty)
    }
}

@MainActor
final class HookHandlingTests: XCTestCase {
    private var db: DatabaseQueue!
    private var store: AppStore!
    private var sessionId: Int64!

    override func setUp() async throws {
        db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        store = makeIsolatedStore(db: db)
        try store.addProject(at: try makeTempRepo())
        try store.createSession(projectId: store.projects[0].id!, model: nil, prompt: nil)
        sessionId = store.sessions[0].id
    }

    private func event(_ name: String, _ claudeId: String? = nil, notification: String? = nil) -> HookPayload {
        HookPayload(event: name, claudeSessionId: claudeId ?? store.sessions[0].claudeSessionId,
                    notificationType: notification, toolName: name == "PreToolUse" ? "Bash" : nil)
    }

    func testTurnGoesThinkingThenWaitingAndNotifiesOnce() {
        XCTAssertNil(store.handleHookEvent(event("UserPromptSubmit"), sessionId: sessionId))
        XCTAssertEqual(store.sessions[0].status, .thinking)
        XCTAssertEqual(store.handleHookEvent(event("PermissionRequest"), sessionId: sessionId), .permission)
        XCTAssertNil(store.handleHookEvent(event("Notification", notification: "permission_prompt"), sessionId: sessionId))
        XCTAssertEqual(store.waitingCount, 1)
        XCTAssertNil(store.handleHookEvent(event("PostToolUse"), sessionId: sessionId))
        XCTAssertEqual(store.handleHookEvent(event("Stop"), sessionId: sessionId), .done)
        XCTAssertEqual(store.sessions[0].status, .waitingInput)
    }

    func testClearMovesSessionToNewClaudeIdSoRestoreResumesIt() {
        store.handleHookEvent(event("SessionStart", "new-id-after-clear"), sessionId: sessionId)
        XCTAssertEqual(store.sessions[0].claudeSessionId, "new-id-after-clear")
        // Other events never rewrite the id.
        store.handleHookEvent(event("Stop", "something-else"), sessionId: sessionId)
        XCTAssertEqual(store.sessions[0].claudeSessionId, "new-id-after-clear")
    }

    func testFeedShowsSelectedSessionNewestFirst() {
        store.handleHookEvent(event("UserPromptSubmit"), sessionId: sessionId)
        store.handleHookEvent(event("PermissionDenied"), sessionId: sessionId)
        XCTAssertEqual(store.selectedEvents.map(\.name), ["PermissionDenied", "UserPromptSubmit"])
        XCTAssertEqual(store.selectedEvents.first?.isFailure, true)
    }

    func testUnknownSessionIsIgnored() {
        XCTAssertNil(store.handleHookEvent(event("Stop"), sessionId: 999))
        XCTAssertTrue(store.selectedEvents.isEmpty)
    }

    func testStatusesResetWhenMeepoRestarts() {
        store.handleHookEvent(event("PermissionRequest"), sessionId: sessionId)
        let restarted = makeIsolatedStore(db: db)
        XCTAssertEqual(restarted.sessions[0].status, .idle)
        XCTAssertEqual(restarted.waitingCount, 0)
    }
}

final class NotifyGuardTests: XCTestCase {
    /// Verbatim layout of the user's MDS/invoke project settings.
    private let projectSettings = """
    {
      "hooks": {
        "Stop": [
          { "hooks": [ { "type": "command", "command": "\\"$CLAUDE_PROJECT_DIR\\"/.claude/hooks/stop-verify.sh" } ] }
        ],
        "Notification": [
          { "hooks": [ { "type": "command", "command": "\\"$CLAUDE_PROJECT_DIR\\"/.claude/hooks/notify-macos.sh" } ] }
        ]
      }
    }
    """

    func testGuardChangesOnlyTheNotificationLineAndRoundTrips() {
        let (guarded, changed) = NotifyGuard.guarded(projectSettings)
        XCTAssertEqual(changed, 1)
        let diff = zip(projectSettings.split(separator: "\n"), guarded.split(separator: "\n")).filter { $0 != $1 }
        XCTAssertEqual(diff.count, 1)
        XCTAssertTrue(diff[0].1.contains(#"[ -n \"$MEEPO_SESSION_ID\" ] || \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/notify-macos.sh"#))
        XCTAssertEqual(NotifyGuard.guarded(guarded).1, 0) // idempotent
        XCTAssertEqual(NotifyGuard.unguarded(guarded).0, projectSettings) // byte-for-byte restore
    }

    /// invoke, 2026-09-24: its committed .claude/settings.json showed Meepo's guard in `git diff`.
    func testCommittedProjectSettingsAreNeverGuardedAndAnOldGuardIsTakenBack() throws {
        let tracked = try makeTempRepo(), untracked = try makeTempRepo()
        for repo in [tracked, untracked] {
            try FileManager.default.createDirectory(at: repo.appending(path: ".claude"), withIntermediateDirectories: true)
        }
        try NotifyGuard.guarded(projectSettings).0.write(to: tracked.appending(path: ".claude/settings.json"), atomically: true, encoding: .utf8)
        try git(["add", ".claude/settings.json"], in: tracked)
        try projectSettings.write(to: untracked.appending(path: ".claude/settings.json"), atomically: true, encoding: .utf8)

        let home = FileManager.default.temporaryDirectory.appending(path: "ng-\(UUID().uuidString)")
        let bridge = BridgeInstaller(settingsURL: home.appending(path: "settings.json"), meepoHome: home)
        try bridge.setNotifyGuard(true, projectPaths: [tracked.path, untracked.path])

        XCTAssertEqual(try String(contentsOf: tracked.appending(path: ".claude/settings.json"), encoding: .utf8), projectSettings)
        XCTAssertTrue(try String(contentsOf: untracked.appending(path: ".claude/settings.json"), encoding: .utf8).contains("MEEPO_SESSION_ID"))
    }

    func testBridgeAndAmbiguousCommandsAreLeftAlone() {
        let text = """
        {"hooks":{"Notification":[{"hooks":[{"type":"command","command":"/h/.meepo/bin/meepo-bridge.sh"},{"type":"command","command":"n.sh"}]}],
        "Stop":[{"hooks":[{"type":"command","command":"n.sh"}]}]}}
        """
        XCTAssertEqual(NotifyGuard.guarded(text).1, 0)
    }

    func testGuardedHookRunsOutsideMeepoAndStaysSilentInside() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let marker = dir.appending(path: "notified")
        let command = NotifyGuard.prefix + "touch '\(marker.path)'"
        func run(_ env: [String: String]) throws {
            let p = Process()
            p.executableURL = URL(filePath: "/bin/bash")
            p.arguments = ["-c", command]
            p.environment = env
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0) // never reported to claude as a hook error
        }
        try run(["MEEPO_SESSION_ID": "3"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        try run([:])
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }
}

final class QuestionTests: XCTestCase {
    /// Real shape: Claude's multiple-choice question arrives as a PermissionRequest for AskUserQuestion.
    private let json = #"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Какую схему взять?","header":"Схема","options":[]}]}}"#

    func testQuestionShowsTheQuestionAndWaitsForInputNotPermission() throws {
        let p = try XCTUnwrap(HookPayload(json: Data(json.utf8)))
        XCTAssertTrue(p.isQuestion)
        XCTAssertEqual(p.summary, "Какую схему взять?")
        XCTAssertEqual(p.status, .waitingInput)
    }

    @MainActor
    func testQuestionNotifiesAsQuestionNotAsDone() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        try store.addProject(at: try makeTempRepo())
        try store.createSession(projectId: store.projects[0].id!, model: nil, prompt: nil)
        let id = store.sessions[0].id!
        store.handleHookEvent(HookPayload(event: "UserPromptSubmit", claudeSessionId: "s"), sessionId: id)
        XCTAssertEqual(store.handleHookEvent(try XCTUnwrap(HookPayload(json: Data(json.utf8))), sessionId: id), .question)
        // Real sequence: ~6 s later Claude Code echoes it as Notification(permission_prompt).
        let echo = HookPayload(event: "Notification", claudeSessionId: "s", notificationType: "permission_prompt")
        XCTAssertNil(store.handleHookEvent(echo, sessionId: id))
        XCTAssertEqual(store.sessions[0].status, .waitingInput)
    }
}

final class NotificationTextTests: XCTestCase {
    func testMarkdownAnswerBecomesOneCleanLine() {
        // The answer from the user's screenshot.
        let answer = "Задам вопросы прямо здесь, текстом:\n\n1. **Формулировка.** Что написать про `thedrain`?\n- см. [доку](https://x.y)"
        XCTAssertEqual(Notifier.plainText(answer),
                       "Задам вопросы прямо здесь, текстом: 1. Формулировка. Что написать про thedrain? см. доку")
    }

    func testLongTextIsCutWithEllipsis() {
        let text = Notifier.plainText(String(repeating: "слово ", count: 100), limit: 20)
        XCTAssertEqual(text.count, 20)
        XCTAssertTrue(text.hasSuffix("…"))
    }
}

/// macOS 15 draws Canvas from SwiftUI's DisplayLink thread; a main-actor renderer traps there (Rustem, 2026-09-24).
final class CanvasRendererTests: XCTestCase {
    func testRenderersAreMadeOffTheMainActor() async {
        // Calling them from a background task compiles only while they stay nonisolated.
        let made = await Task.detached { () -> Bool in
            _ = ContextBar.renderer(fraction: 0.6)
            return true
        }.value
        XCTAssertTrue(made)
    }
}
