import GRDB
import XCTest
@testable import Meepo

final class GuidedSettingsTests: XCTestCase {
    func testGuidedSessionsExplainAndAskBeforeRiskyThings() throws {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(ClaudeLauncher.sessionSettings(effort: nil, guided: true)[1].utf8)) as? [String: Any])
        XCTAssertEqual(json["outputStyle"] as? String, "Explanatory")
        let ask = try XCTUnwrap((json["permissions"] as? [String: Any])?["ask"] as? [String])
        XCTAssertTrue(ask.contains("Bash(git push:*)"))
        XCTAssertTrue(ask.contains("Edit(**/.env*)"))
        XCTAssertNil((json["permissions"] as? [String: Any])?["allow"], "guided mode never allows anything new")
    }

    func testOthersGetNeither() throws {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(ClaudeLauncher.sessionSettings(effort: nil)[1].utf8)) as? [String: Any])
        XCTAssertNil(json["outputStyle"])
        XCTAssertNil(json["permissions"])
    }
}

@MainActor
final class NewProjectTests: XCTestCase {
    func testANewProjectIsAGitFolderInMeepo() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "np-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!
        let store = AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "s.json"), meepoHome: tmp),
                             usageRoot: tmp, defaults: defaults)
        let project = try XCTUnwrap(try store.createProject(named: "my-first-app", in: tmp))
        XCTAssertEqual(project.name, "my-first-app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appending(path: "my-first-app/.git").path))
        XCTAssertThrowsError(try store.createProject(named: "my-first-app", in: tmp), "never on top of an existing folder") { error in
            XCTAssertFalse(error.localizedDescription.contains("with +"), "Welcome has no + button")
        }
        XCTAssertThrowsError(try store.createProject(named: "  ", in: tmp))

        store.guidedMode = true
        let again = AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "s.json"), meepoHome: tmp),
                             usageRoot: tmp, defaults: defaults)
        XCTAssertTrue(again.guidedMode, "the choice outlives a restart")
    }
}

@MainActor
final class GuidedRestartTests: XCTestCase {
    private func state(_ id: Int64, _ status: SessionStatus, _ last: String?, guided: Bool = false) -> AppStore.TurnState {
        AppStore.TurnState(id: id, status: status, lastEvent: last, runsGuided: guided)
    }

    func testOnlySessionsBetweenTurnsRestartNow() {
        let sessions = [state(1, .idle, "SessionStart"), state(2, .waitingInput, "Stop"), state(3, .thinking, "PreToolUse"),
                        state(4, .waitingPermission, "PermissionRequest"), state(5, .idle, "SessionStart", guided: true),
                        state(6, .idle, nil)]
        let (now, later) = AppStore.guidedRestart(sessions, guided: true, hooks: true)
        XCTAssertEqual(now, [1, 2], "ready, or Claude's answer was the last word")
        XCTAssertEqual(later, [3, 4, 6], "mid-turn or asking permission; 5 already runs guided; 6: no hook seen yet")
        XCTAssertEqual(AppStore.guidedRestart(sessions, guided: false, hooks: true).now, [5], "turning it off restarts the guided ones")
    }

    /// Without the hook bridge nothing moves a session off idle — it may be mid-turn: none restarts now.
    func testWithoutHooksIdleIsUnknown() {
        let sessions = [state(1, .idle, nil), state(2, .idle, "SessionStart")]
        XCTAssertEqual(AppStore.guidedRestart(sessions, guided: true, hooks: false).now, [])
        XCTAssertEqual(AppStore.guidedRestart(sessions, guided: true, hooks: false).later, [1, 2])
    }

    /// A session claude only (re)started, left alone until the idle prompt came (status "waiting for you" after
    /// SessionStart — every session right after meepo opens), and one whose turn an API error ended, are between turns.
    func testAFreshlyStartedOrFailedSessionIsBetweenTurns() {
        let sessions = [state(1, .waitingInput, "SessionStart"), state(2, .error, "StopFailure"),
                        state(3, .waitingInput, nil), state(4, .error, "PreToolUse")]
        let (now, later) = AppStore.guidedRestart(sessions, guided: true, hooks: true)
        XCTAssertEqual(now, [1, 2])
        XCTAssertEqual(later, [3, 4], "nothing known about its turn: don't cut it off")
    }

    /// The notice's Restart (or OK) restarts only the sessions it named: one that finished while it was open wasn't
    /// offered, and the user didn't agree to restart it. Demo mode: a restart only flips the mode, no claude runs.
    func testRestartTouchesOnlyTheSessionsTheNoticeNamed() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        await store.loadDemo()
        func session(_ name: String) throws -> Session { try XCTUnwrap(store.sessions.first { $0.name == name }) }
        let working = try session("kaspi refunds"), ready = try session("welcome screen"), answered = try session("login bug")
        XCTAssertEqual(store.sessions.first { $0.id == working.id }?.status, .thinking)

        store.setGuidedMode(true)
        let notice = try XCTUnwrap(store.confirmation)
        XCTAssertEqual(notice.action, "Restart 2 sessions")
        let message = try XCTUnwrap(notice.message)
        XCTAssertTrue(message.contains("mobile, storefront · login bug"), "says which: \(message)")
        XCTAssertTrue(message.contains("old mode for now: storefront · kaspi refunds, fleet-api."), message)
        // Claude finishes the working session while the notice is still open.
        store.handleHookEvent(HookPayload(event: "Stop", claudeSessionId: working.claudeSessionId, lastAssistantMessage: "Done."),
                              sessionId: working.id!)
        notice.perform()
        XCTAssertTrue(store.modelLine(of: ready).hasSuffix("· guided"))
        XCTAssertTrue(store.modelLine(of: answered).hasSuffix("· guided"))
        XCTAssertFalse(store.modelLine(of: working).hasSuffix("· guided"), "not named in the notice: not restarted")
    }

    /// A question Claude asked (AskUserQuestion) reads "waiting for you" like a finished answer — but it's still its turn.
    func testAnOpenQuestionIsBusy() {
        let asking = state(1, .waitingInput, "PermissionRequest")
        XCTAssertEqual(AppStore.guidedRestart([asking], guided: true, hooks: true).now, [])
        XCTAssertEqual(AppStore.guidedRestart([asking], guided: true, hooks: true).later, [1])
    }

    /// The store keeps each session's last turn event from its hooks; a later idle-prompt Notification — the same
    /// "waiting for you" — must not make an open question look answered.
    func testTheStoreSeesAnOpenQuestion() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        try store.addProject(at: try makeTempRepo())
        try store.createSession(projectId: store.projects[0].id!, model: nil, prompt: nil)
        let session = store.sessions[0], id = session.id!
        store.handleHookEvent(HookPayload(event: "PermissionRequest", claudeSessionId: session.claudeSessionId,
                                          toolName: "AskUserQuestion", toolTarget: "Which color?"), sessionId: id)
        store.handleHookEvent(HookPayload(event: "Notification", claudeSessionId: session.claudeSessionId,
                                          notificationType: "idle_prompt"), sessionId: id)
        XCTAssertEqual(store.sessions[0].status, .waitingInput)
        XCTAssertEqual(store.lastTurnEvents[id], "PermissionRequest")
        XCTAssertEqual(AppStore.guidedRestart([AppStore.TurnState(id: id, status: .waitingInput, lastEvent: store.lastTurnEvents[id],
                                                                  runsGuided: false)], guided: true, hooks: true).now, [])
        store.handleHookEvent(HookPayload(event: "Stop", claudeSessionId: session.claudeSessionId, lastAssistantMessage: "Blue."),
                              sessionId: id)
        XCTAssertEqual(store.lastTurnEvents[id], "Stop")

        store.setGuidedMode(true)
        XCTAssertTrue(store.guidedMode)
        XCTAssertEqual(store.confirmation?.action, "OK", "no claude runs in tests: nothing to restart, only the explanation")
        XCTAssertNil(store.confirmation?.cancel)
    }
}

@MainActor
final class FinishOnboardingTests: XCTestCase {
    func testTheFirstRunOpensASessionWhereClaudeWorks() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        try store.addProject(at: try makeTempRepo())
        store.isHomeShown = true
        try store.finishOnboarding(newcomer: true, guided: true, projectId: store.projects[0].id, isFirstRun: true)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.selectedSessionId, store.sessions[0].id, "Start opens it")
        XCTAssertFalse(store.isHomeShown)
        XCTAssertTrue(store.guidedMode)
        XCTAssertEqual(store.shellPreset, .focus)
    }

    /// ≡ → Welcome again: the layout set up once stays, and so does Guided mode (commit 2ad5756's promise).
    func testWelcomeAgainChangesNeitherLayoutNorGuidedMode() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        store.applyPreset(.full)
        store.editShell { $0.split = 1 }
        let layout = store.shell
        store.guidedMode = false
        try store.finishOnboarding(newcomer: true, guided: true, projectId: nil, isFirstRun: false)
        XCTAssertEqual(store.shellPreset, .full)
        XCTAssertEqual(store.shell, layout)
        XCTAssertFalse(store.guidedMode)
        XCTAssertTrue(store.sessions.isEmpty, "no project picked, no session")
    }
}

@MainActor
final class DemoGitTests: XCTestCase {
    /// The user's global git config — commit signing, a hooks folder — stays out of Demo's made-up commits.
    func testDemoCommitsIgnoreTheUsersGitConfig() async throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "demo-git-\(UUID().uuidString)")
        let hooks = tmp.appending(path: "hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 1\n".write(to: hooks.appending(path: "pre-commit"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks.appending(path: "pre-commit").path)
        let config = tmp.appending(path: "gitconfig")
        try "[commit]\n\tgpgsign = true\n[gpg]\n\tprogram = /usr/bin/false\n[core]\n\thooksPath = \(hooks.path)\n"
            .write(to: config, atomically: true, encoding: .utf8)
        setenv("GIT_CONFIG_GLOBAL", config.path, 1)
        defer { unsetenv("GIT_CONFIG_GLOBAL") }

        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        await store.loadDemo()
        let folder = FileManager.default.temporaryDirectory.appending(path: "Meepo Demo/\(Demo.projects[0].name)")
        let count = Int(GitService.output(["rev-list", "--count", "HEAD"], in: folder.path) ?? "") ?? 0
        XCTAssertEqual(count, 1 + Demo.projects[0].history.count, "every commit made, none signed or blocked by a hook")
    }
}
