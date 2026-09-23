import GRDB
import XCTest
@testable import Meepo

/// Shape of a real `gh run view --log-failed` (2026-09-23): "job<TAB>UNKNOWN STEP<TAB>timestamp line", whole job.
private func ghLog(_ lines: [String]) -> String {
    lines.map { "backend\tUNKNOWN STEP\t2026-09-23T06:06:47.4679532Z \($0)" }.joined(separator: "\n")
}

private let realisticLog = ghLog([
    "##[group]Run pip install -r requirements.txt",
    "Collecting django==5.2",
    "##[endgroup]",
    "##[group]Run python manage.py test --noinput",
    "\u{1B}[36;1mpython manage.py test --noinput\u{1B}[0m",
    "Traceback (most recent call last):",           // caught-and-logged noise, repeated
    "FileNotFoundError: firebase-admin-key.json",
    "Traceback (most recent call last):",
    "FileNotFoundError: firebase-admin-key.json",
    "======================================================================",
    "ERROR: test_sync_bulk_update (sapar.test_auto_sign.FlagWritersTests.test_sync_bulk_update)",
    "----------------------------------------------------------------------",
    "Traceback (most recent call last):",
    "  File \"sapar/test_auto_sign.py\", line 88, in test_sync_bulk_update",
    "KeyError: 'since'",
    "----------------------------------------------------------------------",
] + (1...200).map { "Сотрудник поддержки создан: #\($0)" } + [
    "Ran 2315 tests in 313.056s",
    "FAILED (errors=1)",
    "##[error]Process completed with exit code 1.",
    "Cleaning up orphan processes",
])

final class CILogTests: XCTestCase {
    func testKeepsTheFailingTestAndSummaryDropsNoise() {
        let trimmed = CILog.trim(realisticLog)
        XCTAssertTrue(trimmed.contains("##[group]Run python manage.py test --noinput"))
        XCTAssertTrue(trimmed.contains("ERROR: test_sync_bulk_update"))
        XCTAssertTrue(trimmed.contains("KeyError: 'since'"))
        XCTAssertTrue(trimmed.contains("FAILED (errors=1)"))
        XCTAssertFalse(trimmed.contains("pip install"))                 // earlier, passing step
        XCTAssertFalse(trimmed.contains("firebase-admin-key"))          // logged noise, not the failure
        XCTAssertFalse(trimmed.contains("UNKNOWN STEP") || trimmed.contains("2026-09-23T"))
        XCTAssertFalse(trimmed.contains("\u{1B}["))
        XCTAssertLessThan(trimmed.count, realisticLog.count / 5)
    }

    func testWithoutErrorMarkerFallsBackToTail() {
        let trimmed = CILog.trim(ghLog((1...500).map { "line \($0)" }))
        XCTAssertTrue(trimmed.hasSuffix("line 500"))
        XCTAssertFalse(trimmed.contains("line 100\n"))
    }
}

private func ciRun(_ id: Int64, workflow: String = "CI", branch: String = "feature", conclusion: String? = "failure",
                 attempt: Int = 1, minutesAgo: Double = 0) -> CIRun {
    let json = """
        {"databaseId":\(id),"workflowName":"\(workflow)","headBranch":"\(branch)","headSha":"abc123","status":"completed",
         "conclusion":\(conclusion.map { "\"\($0)\"" } ?? "null"),"createdAt":"\(ISO8601DateFormatter().string(from: .now.addingTimeInterval(-minutesAgo * 60)))",
         "attempt":\(attempt),"url":"https://github.com/o/r/actions/runs/\(id)"}
        """
    return try! GitHubActions.decoder.decode(CIRun.self, from: Data(json.utf8))
}

final class CIGuardTests: XCTestCase {
    func testRulesFromTheSpec() {
        XCTAssertEqual(CIGuard.action(for: ciRun(1, conclusion: "success"), fixAttempts: 0, autofix: true), .none)
        XCTAssertEqual(CIGuard.action(for: ciRun(1), fixAttempts: 0, autofix: false), .none)          // notify only
        XCTAssertEqual(CIGuard.action(for: ciRun(1), fixAttempts: 0, autofix: true), .rerun)          // flaky first
        XCTAssertEqual(CIGuard.action(for: ciRun(1, attempt: 2), fixAttempts: 0, autofix: true), .fix)
        XCTAssertEqual(CIGuard.action(for: ciRun(1, attempt: 2), fixAttempts: 3, autofix: true), .giveUp)
        XCTAssertEqual(CIGuard.action(for: ciRun(1, workflow: "Build & Push"), fixAttempts: 0, autofix: true), .reportDeploy)
        XCTAssertTrue(ciRun(1, workflow: "Deploy to prod").isDeploy)
        XCTAssertFalse(ciRun(1, workflow: "CI").isDeploy)
    }

    func testFixPromptCarriesContextAndGuardrails() {
        let prompt = CIGuard.fixPrompt(ciRun(42, branch: "TransactionsService", attempt: 2), log: "KeyError: 'since'")
        XCTAssertTrue(prompt.contains("KeyError: 'since'"))
        XCTAssertTrue(prompt.contains("git checkout -B ci-fix/TransactionsService-42 origin/TransactionsService"))
        XCTAssertTrue(prompt.contains("gh pr create"))
        XCTAssertTrue(prompt.contains("Never push to main, master"))
        XCTAssertTrue(prompt.contains("never force-push"))
    }
}

private final class FakeCI: CIProvider, @unchecked Sendable {
    var runs: [CIRun] = []
    var reruns: [Int64] = []
    func handles(_ project: Project) -> Bool { true }
    func runs(in path: String) async -> [CIRun] { runs }
    func failedLog(_ run: CIRun, in path: String) async -> String { "KeyError: 'since'" }
    func rerunFailed(_ run: CIRun, in path: String) async -> Bool { reruns.append(run.id); return true }
}

@MainActor
final class CIWatcherTests: XCTestCase {
    private var store: AppStore!
    private var ci: FakeCI!
    private var notices: [String] = []

    override func setUp() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        store = makeIsolatedStore(db: db)
        let repo = try makeTempRepo(remote: "git@github.com:me/app.git")
        try git(["commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        try store.addProject(at: repo)
        ci = FakeCI()
        store.ciProvider = ci
        store.onCINotice = { [weak self] title, _ in self?.notices.append(title) }
    }

    private var projectId: Int64 { store.projects[0].id! }

    /// SPEC module 9 "done when": a failed CI turns into a fix PR session without the user, or a clear notice why not.
    func testFailureIsRerunThenFixedThenGivenUp() async {
        ci.runs = [ciRun(1, minutesAgo: 60)]
        await store.refreshCI()                                          // launch: history is not acted on
        XCTAssertTrue(ci.reruns.isEmpty && notices.isEmpty && store.sessions.isEmpty)

        store.autofixProjectIds = [projectId]
        ci.runs = [ciRun(2, minutesAgo: 1)]
        await store.refreshCI()
        XCTAssertEqual(ci.reruns, [2])                                   // 1. flaky? rerun once
        await store.refreshCI()
        XCTAssertEqual(ci.reruns, [2])                                   // each failure is handled once

        ci.runs = [ciRun(2, attempt: 2)]
        await store.refreshCI()                                          // 2–3. still red → fix session
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].worktreeName, "ci-fix-feature-2")
        XCTAssertTrue(store.initialPrompts[store.sessions[0].id!]!.contains("KeyError: 'since'"))

        for id in 3...4 { ci.runs = [ciRun(Int64(id), attempt: 2)]; await store.refreshCI() }
        XCTAssertEqual(store.sessions.count, 3)
        ci.runs = [ciRun(5, attempt: 2)]
        await store.refreshCI()                                          // 4. limit of 3 fixes
        XCTAssertEqual(store.sessions.count, 3)
        XCTAssertEqual(notices.last, "CI still failing — gave up")

        ci.runs = [ciRun(6, conclusion: "success")]
        await store.refreshCI()                                          // green again resets the limit
        ci.runs = [ciRun(7, attempt: 2)]
        await store.refreshCI()
        XCTAssertEqual(store.sessions.count, 4)
    }

    func testWithoutAutofixOnlyNotifiesAndDeploysAreNeverFixed() async {
        await store.refreshCI()
        ci.runs = [ciRun(10), ciRun(11, workflow: "Build & Push", branch: "main")]
        await store.refreshCI()
        XCTAssertTrue(ci.reruns.isEmpty && store.sessions.isEmpty)
        XCTAssertEqual(Set(notices), ["CI failed", "Deploy failed"])

        store.autofixProjectIds = [projectId]
        ci.runs = [ciRun(12, workflow: "Deploy prod", branch: "main", attempt: 2)]
        await store.refreshCI()
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(notices.last, "Deploy failed")
    }

    func testCardShowsWorstStateOnTheSessionBranch() async throws {
        try store.createSession(projectId: projectId, model: nil, prompt: nil)
        let branch = store.sessions[0].branch!
        ci.runs = [ciRun(20, workflow: "CI", branch: branch, conclusion: "success"),
                   ciRun(21, workflow: "Lint", branch: branch), ciRun(22, branch: "other", conclusion: "success")]
        await store.refreshCI()
        XCTAssertEqual(store.ciState(for: store.sessions[0])?.id, 21)
    }
}
