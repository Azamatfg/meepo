import GRDB
import XCTest
@testable import Meepo

/// A shared remote with the user's clone (the Meepo project) and a teammate's clone.
private struct Team {
    let remote: URL, mine: URL, theirs: URL

    init() throws {
        let tmp = FileManager.default.temporaryDirectory
        remote = tmp.appending(path: "team-\(UUID().uuidString).git")
        try git(["init", "-q", "--bare", "-b", "main", remote.path], in: tmp)
        mine = try makeTempRepo()
        try git(["checkout", "-q", "-B", "main"], in: mine)
        try "base\n".write(to: mine.appending(path: "shared.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: mine)
        try git(["commit", "-q", "-m", "base"], in: mine)
        try git(["remote", "add", "origin", remote.path], in: mine)
        try git(["push", "-q", "-u", "origin", "main"], in: mine)
        theirs = tmp.appending(path: "teammate-\(UUID().uuidString)")
        try git(["clone", "-q", remote.path, theirs.path], in: tmp)
    }

    func teammateCommits(_ file: String, _ text: String, _ message: String) throws {
        try text.write(to: theirs.appending(path: file), atomically: true, encoding: .utf8)
        try git(["add", "."], in: theirs)
        try git(["-c", "user.email=rustem@team", "-c", "user.name=Rustem", "commit", "-q", "-m", message], in: theirs)
        try git(["push", "-q"], in: theirs)
    }
}

final class PullRebaseTests: XCTestCase {
    /// A conflict never leaves a half-done rebase: the folder is exactly as before.
    func testConflictIsAbortedAndNothingChanges() throws {
        let team = try Team()
        try team.teammateCommits("shared.txt", "theirs\n", "teammate edit")
        try "mine\n".write(to: team.mine.appending(path: "shared.txt"), atomically: true, encoding: .utf8)
        try git(["commit", "-q", "-am", "my edit"], in: team.mine)
        let before = GitService.headCommit(in: team.mine.path)

        XCTAssertNotNil(GitPanel.pullRebase(in: team.mine.path))
        XCTAssertEqual(GitService.headCommit(in: team.mine.path), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: team.mine.appending(path: ".git/rebase-merge").path))
        XCTAssertEqual(try String(contentsOf: team.mine.appending(path: "shared.txt"), encoding: .utf8), "mine\n")
    }

}

/// The user's discomfort (2026-09-24): "↑1 ↓1" said nothing. Now each side is spelled out, like VS Code.
final class SourceControlTests: XCTestCase {
    func testYoursTheirsAndUncommittedAreSeparate() throws {
        let team = try Team()
        try team.teammateCommits("api.py", "def f():\n    return 1\n", "add api endpoint")
        try "m\n".write(to: team.mine.appending(path: "mine.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: team.mine)
        try git(["commit", "-q", "-m", "my feature"], in: team.mine)
        try "wip\n".write(to: team.mine.appending(path: "shared.txt"), atomically: true, encoding: .utf8)
        GitPanel.fetch(in: team.mine.path)

        let scm = GitPanel.sourceControl(in: team.mine.path)
        XCTAssertEqual(scm.changes.map(\.path), ["shared.txt"])                       // not committed yet
        XCTAssertEqual(scm.incoming.commits.map(\.author), ["Rustem"])
        XCTAssertEqual(scm.incoming.commits.map(\.subject), ["add api endpoint"])
        XCTAssertEqual(scm.incoming.files.map(\.path), ["api.py"])                  // only their files
        XCTAssertEqual(scm.outgoing.commits.map(\.subject), ["my feature"])
        XCTAssertEqual(scm.outgoing.files.map(\.path), ["mine.txt"])
        XCTAssertEqual([scm.ahead, scm.behind], [1, 1])

        // COMPARE on their file: nothing before, their version after.
        let theirs = GitPanel.versions(of: scm.incoming.files[0], old: scm.incoming.from, new: scm.incoming.to, in: team.mine.path)
        XCTAssertNil(theirs.old)
        XCTAssertEqual(theirs.new.map { String(decoding: $0, as: UTF8.self) }, "def f():\n    return 1\n")
    }
}

@MainActor
final class AutoSyncStoreTests: XCTestCase {
    private func store(for team: Team) throws -> (AppStore, Session) {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        try store.addProject(at: team.mine)
        try store.createSession(projectId: store.projects[0].id!, model: nil, prompt: nil)
        return (store, store.sessions[0])
    }

    func testCleanFolderIsPulledAndTheAgentHearsOnce() async throws {
        let team = try Team()
        let (store, session) = try store(for: team)
        try team.teammateCommits("api.py", "def f(): pass\n", "add api endpoint")

        await store.autoSync(only: [session])
        XCTAssertTrue(FileManager.default.fileExists(atPath: team.mine.appending(path: "api.py").path))  // pulled
        let prompt = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"x","prompt":"go on"}"#.utf8)
        let note = try XCTUnwrap(store.hookReply(sessionId: session.id!, body: prompt))
        XCTAssertTrue(note.contains("already pulled"))
        XCTAssertTrue(note.contains("Rustem: add api endpoint"))
        XCTAssertTrue(note.contains("api.py"))
        XCTAssertNil(store.hookReply(sessionId: session.id!, body: prompt))                         // once

        await store.autoSync(only: [session])                                                      // nothing new
        XCTAssertNil(store.hookReply(sessionId: session.id!, body: prompt))
    }

    /// Uncommitted work: no pull, no stash — the agent is told to commit and rebase itself.
    func testDirtyFolderWaitsAndTheAgentIsTold() async throws {
        let team = try Team()
        let (store, session) = try store(for: team)
        try team.teammateCommits("api.py", "x\n", "teammate work")
        try "wip\n".write(to: team.mine.appending(path: "wip.txt"), atomically: true, encoding: .utf8)
        let before = GitService.headCommit(in: team.mine.path)

        await store.autoSync(only: [session])
        XCTAssertEqual(GitService.headCommit(in: team.mine.path), before)
        XCTAssertTrue(store.pendingPulls.contains(team.mine.path))
        let prompt = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"x","prompt":"go"}"#.utf8)
        XCTAssertTrue(try XCTUnwrap(store.hookReply(sessionId: session.id!, body: prompt)).contains("Not pulled yet"))
        let stashes = try XCTUnwrap(GitService.outputAllowingFailure(["stash", "list"], in: team.mine.path))
        XCTAssertTrue(stashes.isEmpty)
    }
}

/// The real bridge script talking to the real server: Meepo's reply comes out on stdout, which Claude reads.
@MainActor
final class BridgeReplyTests: XCTestCase {
    func testReplyReachesClaudeThroughTheBridge() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "bh-\(UUID().uuidString)")
        let installer = BridgeInstaller(settingsURL: home.appending(path: "settings.json"), meepoHome: home.appending(path: ".meepo"))
        try installer.writeScript()
        let token = try MeepoHome.token(in: home.appending(path: ".meepo"))
        let port = UInt16.random(in: 49_000...59_000)
        let server = EventServer(token: token) { _, _ in }
        server.reply = { id, _ in id == 7 ? "[Meepo] Teammates pushed 1 new commit" : nil }
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(200))

        let out = try await Task.detached { () throws -> String in
            let process = Process()
            process.executableURL = URL(filePath: "/bin/bash")
            process.arguments = [installer.scriptURL.path]
            process.environment = ["HOME": home.path, "MEEPO_SESSION_ID": "7", "MEEPO_PORT": String(port), "PATH": "/usr/bin:/bin"]
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            input.fileHandleForWriting.write(Data(#"{"hook_event_name":"UserPromptSubmit"}"#.utf8))
            try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
        XCTAssertEqual(out, "[Meepo] Teammates pushed 1 new commit")
    }

    func testEmptyReplyIs204WithNoBody() {
        let empty = String(decoding: EventServer.response(status: 204, text: ""), as: UTF8.self)
        XCTAssertTrue(empty.hasPrefix("HTTP/1.1 204") && empty.hasSuffix("\r\n\r\n"))
        let note = String(decoding: EventServer.response(status: 204, text: "hi"), as: UTF8.self)
        XCTAssertTrue(note.hasPrefix("HTTP/1.1 200") && note.hasSuffix("\r\n\r\nhi"))
    }
}
