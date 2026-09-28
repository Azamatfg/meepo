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

    /// NOTES shows the note formatted and COPY carries the bold, so both kinds of prompt ask for that markup.
    func testPromptAsksForMarkupMeepoReads() {
        for style in ["Пост 1\n---\nПост 2", ""] {
            let prompt = ReleaseNotes.prompt(project: "taxinet", commits: "- a", shipReport: nil, style: style)
            XCTAssertTrue(prompt.contains("**bold**") && prompt.contains("no # headings"), style)
        }
    }

    /// Hooks off, no tools, nothing saved; and never `--bare`, which skips the keychain login (checked live, 2.1.281).
    func testHeadlessRunCannotReachTheBridgeOrTools() {
        XCTAssertEqual(ClaudeHeadless.arguments, ["-p", "--tools", "", "--no-session-persistence", "--setting-sources", ""])
        XCTAssertFalse(ClaudeHeadless.arguments.contains("--bare"))
    }

    /// Explain for users is one short call of its own, not a fork of the session's conversation.
    func testExplainIsNotAFork() {
        let args = ClaudeHeadless.jsonArguments(schema: Work.schema)
        XCTAssertFalse(args.contains("--resume") || args.contains("--fork-session"))
        XCTAssertEqual(Array(args.suffix(4)), ["--output-format", "json", "--json-schema", Work.schema])
        XCTAssertEqual(Array(args.prefix(ClaudeHeadless.arguments.count)), ClaudeHeadless.arguments, "no tools, no hooks, nothing saved")
    }

    /// claude exits before reading a big prompt: the run fails with its message, meepo doesn't crash (SIGPIPE, EPIPE).
    func testAClaudeThatExitsEarlyFailsTheRun() async {
        let prompt = String(repeating: "x", count: 1_000_000)
        do {
            _ = try await ClaudeHeadless.run(prompt, claude: "/bin/sh", environment: [:], arguments: ["-c", "echo 'bad flag' >&2; exit 3"])
            XCTFail("exited with 3")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("bad flag"), error.localizedDescription)
        }
    }

    /// A lot on stderr before it exits: read alongside stdout, so neither side waits on the other forever.
    func testALongStderrDoesNotHang() async {
        let failed = expectation(description: "the run ends")
        Task {
            do { _ = try await ClaudeHeadless.run("hi", claude: "/bin/sh", environment: [:],
                                                   arguments: ["-c", "head -c 200000 /dev/zero >&2; exit 1"]) } catch { failed.fulfill() }
        }
        await fulfillment(of: [failed], timeout: 10)
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

    /// Another session of the project answering while /ship runs is not the ship report.
    func testReportComesFromTheSessionThatShipped() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        let repo = try makeTempRepo()
        try git(["commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        try store.addProject(at: repo)
        let projectId = store.projects[0].id!
        try store.createSession(projectId: projectId, model: nil, prompt: nil)
        let shipping = try XCTUnwrap(store.selectedSession)
        try store.createSession(projectId: projectId, model: nil, prompt: nil)
        let other = try XCTUnwrap(store.selectedSession)
        func send(_ event: String, in session: Session, prompt: String? = nil, command: String? = nil, reply: String? = nil) async throws {
            store.handleHookEvent(HookPayload(event: event, claudeSessionId: session.claudeSessionId, prompt: prompt,
                                              lastAssistantMessage: reply, commandName: command), sessionId: session.id!)
            try await Task.sleep(for: .milliseconds(5))
        }

        try await send("UserPromptExpansion", in: shipping, prompt: "/ship", command: "ship")
        try await send("Stop", in: other, reply: "Added the experimental login form")
        try await send("Stop", in: shipping, reply: "Pushed 3 commits, tests green")
        XCTAssertEqual(store.lastShipReport(projectId, after: nil), "Pushed 3 commits, tests green")
    }
}
