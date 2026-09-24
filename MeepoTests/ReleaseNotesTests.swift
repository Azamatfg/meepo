import GRDB
import XCTest
@testable import Meepo

final class ReleaseNotesTests: XCTestCase {
    private func commit(_ message: String, in repo: URL) throws {
        try git(["commit", "-q", "--allow-empty", "-m", message], in: repo)
    }

    /// The next note covers only what came after the previous one; nothing new means no note, not a rerun of old commits.
    func testCommitsStartAfterTheLastNotesSha() throws {
        let repo = try makeTempRepo()
        try commit("feat: login form", in: repo)
        XCTAssertTrue(try XCTUnwrap(ReleaseNotes.commits(after: nil, in: repo.path)).contains("feat: login form"))

        let noted = try XCTUnwrap(GitService.headCommit(in: repo.path))
        XCTAssertNil(ReleaseNotes.commits(after: noted, in: repo.path))

        try commit("feat: kaspi payments\n\nBody line.", in: repo)
        let next = try XCTUnwrap(ReleaseNotes.commits(after: noted, in: repo.path))
        XCTAssertTrue(next.contains("feat: kaspi payments") && next.contains("Body line."))
        XCTAssertFalse(next.contains("login form"))

        // A sha the history no longer has (rebase): fall back to recent commits instead of failing.
        XCTAssertNotNil(ReleaseNotes.commits(after: "0123456789abcdef0123456789abcdef01234567", in: repo.path))
    }

    func testPromptCarriesSamplesCommitsAndShipReport() {
        let prompt = ReleaseNotes.prompt(project: "taxinet", commits: "- abc feat: kaspi", shipReport: "Shipped v1.4", style: "Пост 1\n---\nПост 2")
        XCTAssertTrue(prompt.contains("<samples>\nПост 1"))
        XCTAssertTrue(prompt.contains("- abc feat: kaspi"))
        XCTAssertTrue(prompt.contains("<ship_report>\nShipped v1.4"))

        let bare = ReleaseNotes.prompt(project: "x", commits: "- a", shipReport: nil, style: "  \n")
        XCTAssertFalse(bare.contains("<samples>") || bare.contains("<ship_report>"))
        XCTAssertTrue(bare.contains("No samples yet"))
    }

    /// Hooks off, no tools, nothing saved; and never `--bare`, which skips the keychain login (checked live, 2.1.281).
    func testHeadlessRunCannotReachTheBridgeOrTools() {
        XCTAssertEqual(ClaudeHeadless.arguments, ["-p", "--tools", "", "--no-session-persistence", "--setting-sources", ""])
        XCTAssertFalse(ClaudeHeadless.arguments.contains("--bare"))
    }
}

@MainActor
final class ShipReportTests: XCTestCase {
    func testReportIsTheFirstStopAfterTheLatestShipAndNewerThanTheLastNote() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        let repo = try makeTempRepo()
        try git(["commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        try store.addProject(at: repo)
        let projectId = store.projects[0].id!
        try store.createSession(projectId: projectId, model: nil, prompt: nil)
        let session = store.sessions[0]
        func send(_ event: String, prompt: String? = nil, command: String? = nil, reply: String? = nil) async throws {
            store.handleHookEvent(HookPayload(event: event, claudeSessionId: session.claudeSessionId, prompt: prompt,
                                              lastAssistantMessage: reply, commandName: command), sessionId: session.id!)
            try await Task.sleep(for: .milliseconds(5))
        }

        try await send("Stop", reply: "Plan ready")                       // before any ship: not a report
        XCTAssertNil(store.lastShipReport(projectId, after: nil))
        try await send("UserPromptExpansion", prompt: "/ship", command: "ship")
        try await send("Stop", reply: "Shipped: 3 commits, pushed")
        try await send("Stop", reply: "Answered a follow-up")
        XCTAssertEqual(store.lastShipReport(projectId, after: nil), "Shipped: 3 commits, pushed")
        XCTAssertNil(store.lastShipReport(projectId, after: .now))       // already covered by a newer note
    }
}
