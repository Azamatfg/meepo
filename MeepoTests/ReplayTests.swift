import GRDB
import XCTest
@testable import Meepo

final class ReplayTests: XCTestCase {
    private func write(_ text: String, to path: String, in repo: URL) throws {
        let url = repo.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func commit(_ message: String, in repo: URL) throws {
        try git(["add", "-A"], in: repo)
        try git(["commit", "-q", "-m", message], in: repo)
    }

    /// A repo whose last commit fixes `add` and adds the test that proves it: the shape of a Replay task.
    private func repoWithFix() throws -> (repo: URL, fix: String) {
        let repo = try makeTempRepo()
        try write("def add(a, b):\n    return a - b\n", to: "m.py", in: repo)
        try commit("add", in: repo)
        try write("def add(a, b):\n    return a + b\n", to: "m.py", in: repo)
        try write("import m\nassert m.add(2, 2) == 4\n", to: "tests/test_m.py", in: repo)
        try commit("fix: add adds", in: repo)
        return (repo, try XCTUnwrap(GitService.headCommit(in: repo.path)))
    }

    func testCandidatesAreSmallCommitsThatChangedCodeAndTests() throws {
        let (repo, fix) = try repoWithFix()
        try write("# notes\n", to: "README.md", in: repo)
        try commit("docs: readme", in: repo)                                     // no tests
        try write("import m\nassert m.add(0, 0) == 0\n", to: "tests/test_zero.py", in: repo)
        try commit("test: zero", in: repo)                                       // only tests: nothing to redo
        try write(String(repeating: "x = 1\n", count: Replay.maxLines), to: "big.py", in: repo)
        try write("import big\n", to: "tests/test_big.py", in: repo)
        try commit("feat: a wave", in: repo)                                     // too big for one instruction
        let found = Replay.candidates(in: repo.path)
        XCTAssertEqual(found.map(\.sha), [fix])
        XCTAssertEqual(found.first?.tests, ["tests/test_m.py"])
        XCTAssertEqual(found.first?.subject, "fix: add adds")
    }

    func testTestFilesByTheirUsualNames() {
        for path in ["MeepoTests/QuitTests.swift", "hooks/register.test.ts", "pkg/foo_test.go", "test_foo.py", "src/__tests__/a.js", "spec/a_spec.rb"] {
            XCTAssertTrue(Replay.isTest(path), path)
        }
        for path in ["Meepo/Services/Replay.swift", "src/latest.ts", "contest/main.go", "docs/specs.md", "Meepo/Latest.swift"] {
            XCTAssertFalse(Replay.isTest(path), path)
        }
    }

    /// The agent's copy has no history to read the answer from and no remote; the hidden tests come only after,
    /// over anything the agent wrote at the same path. Doing nothing fails; the commit itself passes.
    func testSnapshotHidesTheAnswerAndTheTestsGradeIt() async throws {
        let (repo, fix) = try repoWithFix()
        let work = FileManager.default.temporaryDirectory.appending(path: "replay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let nop = work.appending(path: "nop"), oracle = work.appending(path: "oracle")
        try Replay.snapshot("\(fix)^", of: repo.path, to: nop)
        XCTAssertEqual(GitService.output(["log", "--format=%s"], in: nop.path), "snapshot")
        XCTAssertNil(GitService.remoteURL(in: nop.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: nop.appending(path: "tests/test_m.py").path))

        try write("assert True\n", to: "tests/test_m.py", in: nop)               // an agent "passing" its own test
        try Replay.putTests(["tests/test_m.py", "tests/deleted.py"], of: fix, from: repo.path, into: nop)
        let check = "cd tests && PYTHONPATH=.. python3 test_m.py"
        let env = ProcessInfo.processInfo.environment
        let nopPassed = await Replay.check(check, in: nop, environment: env)
        XCTAssertFalse(nopPassed)

        try Replay.snapshot(fix, of: repo.path, to: oracle)
        let oraclePassed = await Replay.check(check, in: oracle, environment: env)
        XCTAssertTrue(oraclePassed)
    }

    /// meepo's check is a whole xcodebuild suite: a task runs only the classes its tests hold, building in the copy.
    func testXcodeCheckRunsOnlyTheTaskTestClasses() {
        let base = "xcodebuild -project Meepo.xcodeproj -scheme Meepo test"
        let sources = ["MeepoTests/QuitTests.swift": "final class QuitTests: XCTestCase {}\nfinal class CrashReportTests: XCTestCase {}"]
        let check = Replay.checkCommand(base: base, tests: sources, hasProjectSpec: true)
        XCTAssertTrue(check.hasPrefix("xcodegen generate && \(base) -derivedDataPath .replay-build"), check)
        XCTAssertTrue(check.hasSuffix("-only-testing:MeepoTests/CrashReportTests -only-testing:MeepoTests/QuitTests"), check)
        XCTAssertEqual(Replay.checkCommand(base: "npm test", tests: [:], hasProjectSpec: false), "npm test")
    }

    /// Unattended: tools allowed by list (auto mode is reset under the env scrub), nothing saved to history.
    func testAgentRunsUnattendedOnTheSetup() {
        let args = Replay.agentArguments(Replay.Setup(model: "fable", effort: "high"), project: "/Users/me/app")
        XCTAssertEqual(Array(args.suffix(4)), ["--model", "fable", "--effort", "high"])
        XCTAssertTrue(args.contains("--allowedTools") && args.contains("--no-session-persistence"))
        XCTAssertFalse(args.contains("--permission-mode") || args.contains("--dangerously-skip-permissions"))
        XCTAssertFalse(Replay.agentArguments(Replay.Setup(model: "", effort: ""), project: "/a").contains("--model"))
    }

    /// Bash can't leave the sandbox, the real repo and key folders are closed to Bash and the file tools, and the
    /// user's own settings and hooks stay out.
    func testAgentIsBoxedAwayFromTheRepoAndKeys() throws {
        let args = Replay.agentArguments(Replay.Setup(model: "", effort: ""), project: "/Users/me/app")
        let sources = try XCTUnwrap(args.firstIndex(of: "--setting-sources"))
        XCTAssertEqual(args[sources + 1], "")
        let json = try XCTUnwrap(args.firstIndex(of: "--settings").map { args[$0 + 1] })
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let sandbox = try XCTUnwrap(settings["sandbox"] as? [String: Any])
        XCTAssertEqual(sandbox["enabled"] as? Bool, true)
        XCTAssertEqual(sandbox["allowUnsandboxedCommands"] as? Bool, false, "else Claude retries a blocked command outside it")
        XCTAssertEqual(sandbox["failIfUnavailable"] as? Bool, true, "else no sandbox means no bounds at all")
        XCTAssertEqual((sandbox["filesystem"] as? [String: Any])?["denyRead"] as? [String], ["/Users/me/app"] + Replay.secretFolders)
        let deny = try XCTUnwrap((settings["permissions"] as? [String: Any])?["deny"] as? [String])
        XCTAssertTrue(deny.contains("Read(//Users/me/app/**)") && deny.contains("Edit(~/.ssh/**)"), "\(deny)")

        let env = Replay.agentEnvironment(["PATH": "/bin", "SSH_AUTH_SOCK": "s", "GH_TOKEN": "t", "AWS_PROFILE": "p"])
        XCTAssertEqual(env, ["PATH": "/bin"])
    }

    func testUsageFromTheJSONResult() {
        XCTAssertEqual(Replay.usage(fromJSON: #"{"total_cost_usd":0.25,"duration_ms":90500,"num_turns":12,"result":"done"}"#),
                       Replay.Usage(cost: 0.25, seconds: 90.5, turns: 12))
        XCTAssertNil(Replay.usage(fromJSON: "Error: rate limited"))
    }

    /// What the user typed in this project while working on the commit; commands and one-word answers aren't requests.
    func testRequestsBetweenTheCommits() throws {
        let history = FileManager.default.temporaryDirectory.appending(path: "history-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: history) }
        func line(_ text: String, _ seconds: Double, _ project: String = "/w/app") -> String {
            String(data: try! JSONSerialization.data(withJSONObject: ["display": text, "timestamp": seconds * 1000, "project": project]), encoding: .utf8)!
        }
        try [line("too early to count here", 50), line("make the cart total apply discounts", 150),
             line("да", 160), line("/review", 170), line("also in the worktree please", 180, "/w/app/.claude/worktrees/x"),
             line("another project entirely here", 190, "/w/app-old"), line("too late to count here", 250)]
            .joined(separator: "\n").write(to: history, atomically: true, encoding: .utf8)
        XCTAssertEqual(Replay.requests(in: "/w/app", from: Date(timeIntervalSince1970: 100), to: Date(timeIntervalSince1970: 200), history: history),
                       ["make the cart total apply discounts", "also in the worktree please"])
    }

    /// Editing a task's instruction or check makes it unvalidated again; deleting it takes its runs along.
    @MainActor
    func testEditedTaskNeedsValidatingAgain() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        try store.addProject(at: try makeTempRepo())
        let task = try db.write { db in
            try ReplayTask(projectId: store.projects[0].id!, sha: "abc", subject: "fix", instruction: "Fix it",
                           checkCommand: "true", tests: ["t.py"], isValid: true).inserted(db)
        }
        _ = try db.write { try ReplayRun(taskId: task.id!, model: "opus", effort: "", passed: true).inserted($0) }
        store.reloadReplay()
        var edited = try XCTUnwrap(store.replayTasks.first)
        XCTAssertEqual(edited.tests, ["t.py"])
        edited.instruction = "Fix it properly"
        store.updateReplayTask(edited)
        XCTAssertNil(store.replayTasks.first?.isValid)
        store.deleteReplayTask(task.id!)
        XCTAssertTrue(store.replayTasks.isEmpty && store.replayRuns.isEmpty)
    }
}
