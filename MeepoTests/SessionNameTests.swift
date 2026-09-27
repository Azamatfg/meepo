import GRDB
import XCTest
@testable import Meepo

@MainActor
final class SessionNameTests: XCTestCase {
    func testTwoSessionsOfOneProjectReadDifferently() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "names-\(UUID().uuidString)")
        let store = AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "s.json"), meepoHome: tmp),
                             usageRoot: tmp, defaults: UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!)
        try store.addProject(at: try makeTempRepo())
        let project = store.projects[0].id!
        try store.createSession(projectId: project, model: nil, prompt: nil, name: "  refunds ")
        try store.createSession(projectId: project, model: nil, prompt: nil)
        let (named, plain) = (store.sessions[0], store.sessions[1])
        XCTAssertEqual(store.displayName(of: named), "refunds", "trimmed")

        XCTAssertEqual(store.displayName(of: plain), plain.branch, "nothing yet: the branch")
        store.handleHookEvent(HookPayload(event: "UserPromptSubmit", claudeSessionId: plain.claudeSessionId,
                                          prompt: "<task-notification>\n<summary>Agent \"x\" finished</summary>\n</task-notification>"),
                              sessionId: plain.id!)
        XCTAssertEqual(store.displayName(of: plain), plain.branch, "Claude Code's own turn doesn't name it")
        store.handleHookEvent(HookPayload(event: "UserPromptSubmit", claudeSessionId: plain.claudeSessionId,
                                          prompt: "fix the login page"), sessionId: plain.id!)
        XCTAssertEqual(store.displayName(of: plain), "fix the login page", "then its first typed request")
        let status = try XCTUnwrap(StatusLine(json: Data(#"{"session_id":"x","session_name":"login bug","model":{"id":"m"}}"#.utf8)))
        store.applyStatusLine(status, sessionId: plain.id!)
        XCTAssertEqual(store.displayName(of: plain), "login bug", "Claude Code's own name after /rename")

        store.rename(plain.id!, to: "auth")
        XCTAssertEqual(store.displayName(of: store.sessions[1]), "auth", "the user's name wins")
        store.rename(plain.id!, to: "   ")
        XCTAssertNil(store.sessions[1].name, "blank clears it")
    }

    /// Before its first statusline a session is called what Claude Code calls it: the title in its transcript
    /// (/rename's, else the one Claude Code wrote), over its first request. Read from the store's own ~/.claude.
    func testTheTranscriptsTitleNamesTheSession() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        try store.addProject(at: try makeTempRepo())
        try store.createSession(projectId: store.projects[0].id!, model: nil, prompt: nil)
        let session = store.sessions[0]
        store.handleHookEvent(HookPayload(event: "UserPromptSubmit", claudeSessionId: session.claudeSessionId,
                                          prompt: "давай импорт графика из Excel"), sessionId: session.id!)
        let folder = store.claudeHome.appending(path: "projects/\(ClaudeImport.claudeFolderName(for: store.workdir(of: session)!))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
            {"type":"user","message":{"content":"давай импорт графика из Excel"}}
            {"type":"ai-title","aiTitle":"Импорт графика займа из Excel","sessionId":"\(session.claudeSessionId)"}
            {"type":"last-prompt","lastPrompt":"закоммить и запушь"}
            """.write(to: folder.appending(path: "\(session.claudeSessionId).jsonl"), atomically: true, encoding: .utf8)
        XCTAssertEqual(store.displayName(of: session), "давай импорт графика из Excel")
        await store.refreshTitles()
        XCTAssertEqual(store.displayName(of: session), "Импорт графика займа из Excel")
        XCTAssertTrue(store.claudeHome.path.hasPrefix(FileManager.default.temporaryDirectory.path), "never the real ~/.claude")
    }

    func testTheNameReachesClaudeCode() {
        let args = ClaudeLauncher.claudeArguments(sessionId: "id", resume: false, model: nil, prompt: nil, name: "refunds")
        XCTAssertEqual(Array(args.suffix(2)), ["--name", "refunds"])
        XCTAssertFalse(ClaudeLauncher.claudeArguments(sessionId: "id", resume: false, model: nil, prompt: nil).contains("--name"))
    }
}
