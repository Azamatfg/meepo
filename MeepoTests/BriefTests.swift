import GRDB
import XCTest
@testable import Meepo

final class BriefTests: XCTestCase {
    private func minute(_ m: Int) -> Date { Date(timeIntervalSince1970: Double(m) * 60) }

    private func run(_ id: Int64, conclusion: String, created: Int, updated: Int?) -> CIRun {
        var run = CIRun(databaseId: id, workflowName: "CI", headBranch: "main", headSha: "s", status: "completed",
                        conclusion: conclusion, createdAt: minute(created), attempt: 1, url: "u\(id)")
        run.updatedAt = updated.map(minute)
        return run
    }

    /// A run started before the last answer but failing after it is news; one that failed before isn't.
    func testFailedRunsCountByWhenTheyEnded() {
        let runs = [run(1, conclusion: "failure", created: 90, updated: 110),
                    run(2, conclusion: "failure", created: 50, updated: 60),
                    run(3, conclusion: "success", created: 105, updated: 120),
                    run(4, conclusion: "failure", created: 130, updated: nil)]
        XCTAssertEqual(Brief.failedRuns(runs, since: minute(100)).map(\.id), [1, 4])
    }

    func testDeployWaitsOnlyOnceItMayStart() {
        let deploy = Pipeline.Step(name: "Deploy", state: .manual, trigger: "deploy.yml")
        XCTAssertEqual(Brief.waitingSteps(Pipeline(branch: "main", sha: "s", steps: [.init(name: "CI", state: .passed), deploy])), [deploy])
        XCTAssertEqual(Brief.waitingSteps(Pipeline(branch: "main", sha: "s", steps: [.init(name: "CI", state: .failed), deploy])), [])
        XCTAssertEqual(Brief.waitingSteps(nil), [])
    }

    /// A finished turn also leaves the session at waitingInput: only a question or a permission is listed.
    func testDoneSessionIsNotAsking() {
        XCTAssertNil(Brief.ask(.waitingInput, lastEvent: "Stop"))
        XCTAssertNil(Brief.ask(.waitingInput, lastEvent: "SessionStart"))
        XCTAssertEqual(Brief.ask(.waitingInput, lastEvent: "PermissionRequest"), "asks you a question")
        XCTAssertEqual(Brief.ask(.waitingPermission, lastEvent: "PermissionRequest"), "asks for permission")
        XCTAssertNil(Brief.ask(.thinking, lastEvent: "PreToolUse"))
    }

    func testOwnCommitsAreLeftOut() {
        let log = "Me@Team.dev\tAzamat: mine\nrustem@team\tRustem: theirs\nbroken line"
        XCTAssertEqual(Brief.othersCommits(log, me: "me@team.dev"), ["Rustem: theirs"])
    }

    /// From the upstream, after the moment, without the person's own pushes.
    func testTeammateCommitsSinceTheLastAnswer() throws {
        let tmp = FileManager.default.temporaryDirectory
        let remote = tmp.appending(path: "brief-\(UUID().uuidString).git")
        try git(["init", "-q", "--bare", "-b", "main", remote.path], in: tmp)
        let mine = try makeTempRepo()
        try git(["config", "user.email", "me@team.dev"], in: mine)
        try git(["config", "user.name", "Me"], in: mine)
        try git(["checkout", "-q", "-B", "main"], in: mine)
        try git(["commit", "-q", "--allow-empty", "-m", "base"], in: mine)
        try git(["remote", "add", "origin", remote.path], in: mine)
        try git(["push", "-q", "-u", "origin", "main"], in: mine)
        let theirs = tmp.appending(path: "brief-theirs-\(UUID().uuidString)")
        try git(["clone", "-q", remote.path, theirs.path], in: tmp)
        try git(["config", "user.email", "rustem@team"], in: theirs)
        func teammate(_ message: String) throws {
            try git(["-c", "user.email=rustem@team", "-c", "user.name=Rustem", "commit", "-q", "--allow-empty", "-m", message], in: theirs)
            try git(["push", "-q"], in: theirs)
        }

        try teammate("before")
        Thread.sleep(forTimeInterval: 1.1)
        let since = Date()
        Thread.sleep(forTimeInterval: 1.1)
        try teammate("after")
        try git(["pull", "-q", "--rebase"], in: mine)
        try git(["commit", "-q", "--allow-empty", "-m", "my own"], in: mine)
        try git(["push", "-q"], in: mine)
        GitPanel.fetch(in: mine.path)

        XCTAssertEqual(Brief.teammateCommits(in: mine.path, since: since), ["Rustem: after"])
        XCTAssertEqual(Brief.teammateCommits(in: [mine.path, theirs.path], since: since),
                       [mine.path: ["Rustem: after"], theirs.path: ["Me: my own"]], "each folder fetched and read as its own person")
    }
}

private struct FixingCI: CIProvider {
    func handles(_ project: Project) -> Bool { true }
    func runs(in path: String) async -> [CIRun] { [] }
    func failedLog(_ run: CIRun, in path: String) async -> String { "boom" }
    func rerunFailed(_ run: CIRun, in path: String) async -> Bool { false }
    var reviewRequest: String { "a PR" }
    func pipeline(runs: [CIRun], in path: String) async -> Pipeline? { nil }
    func start(_ step: Pipeline.Step, of pipeline: Pipeline, in path: String) async -> String? { nil }
}

@MainActor
final class BriefStoreTests: XCTestCase {
    /// A Stop moves it, a tool call doesn't; closing the session (its events go with it) keeps it; a CI fix meepo
    /// started alone doesn't move it either.
    func testLastAnswerOutlivesTheSessionAndIgnoresAutofix() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        let repo = try makeTempRepo()
        try git(["commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        try store.addProject(at: repo)
        let project = store.projects[0]
        try store.createSession(projectId: project.id!, model: nil, prompt: nil)
        let session = store.sessions[0]
        XCTAssertNil(store.lastAnswerAt())

        func send(_ event: String, to session: Session) {
            _ = store.handleHookEvent(HookPayload(event: event, claudeSessionId: session.claudeSessionId), sessionId: session.id!)
        }
        send("Stop", to: session)
        let answered = try XCTUnwrap(store.lastAnswerAt())
        send("PreToolUse", to: session)
        XCTAssertEqual(store.lastAnswerAt(), answered)

        store.closeSession(session.id!)
        XCTAssertEqual(store.lastAnswerAt(), answered, "the closed session's Stop events are gone; the answer isn't")

        let run = CIRun(databaseId: 1, workflowName: "CI", headBranch: "main", headSha: "s", status: "completed",
                        conclusion: "failure", createdAt: .now, attempt: 1, url: "u")
        await store.startCIFix(run, in: project, provider: FixingCI())
        let fix = try XCTUnwrap(store.sessions.last)
        send("Stop", to: fix)
        XCTAssertEqual(store.lastAnswerAt(), answered, "nobody was there for the autofix's turn")
    }
}
