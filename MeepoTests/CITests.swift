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
                 attempt: Int = 1, minutesAgo: Double = 0, event: String? = nil) -> CIRun {
    let json = """
        {"databaseId":\(id),"workflowName":"\(workflow)","headBranch":"\(branch)","headSha":"abc123","status":"completed",
         "conclusion":\(conclusion.map { "\"\($0)\"" } ?? "null"),"createdAt":"\(ISO8601DateFormatter().string(from: .now.addingTimeInterval(-minutesAgo * 60)))",
         "attempt":\(attempt),"url":"https://github.com/o/r/actions/runs/\(id)"\(event.map { ",\"event\":\"\($0)\"" } ?? "")}
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

    /// A PR from a fork is only reported, never rerun with the user's rights or handed to an agent; one from a branch
    /// of the repo itself is the user's own.
    func testPullRequestRunsAreOnlyReported() {
        for event in ["pull_request", "pull_request_target"] {
            XCTAssertEqual(CIGuard.action(for: ciRun(1, event: event), fixAttempts: 0, autofix: true), .none)
            XCTAssertEqual(CIGuard.action(for: ciRun(1, attempt: 2, event: event), fixAttempts: 0, autofix: true), .none)
        }
        XCTAssertTrue(ciRun(1, event: "merge_request_event").isPullRequest)          // GitLab's
        XCTAssertEqual(CIGuard.action(for: ciRun(1, event: "push"), fixAttempts: 0, autofix: true), .rerun)
        XCTAssertEqual(CIGuard.action(for: ciRun(1, event: "pull_request"), fixAttempts: 0, autofix: true, ownPullRequest: true), .rerun)
        XCTAssertEqual(CIGuard.action(for: ciRun(1, attempt: 2, event: "pull_request"), fixAttempts: 0, autofix: true, ownPullRequest: true), .fix)
    }

    func testFixPromptCarriesContextAndGuardrails() {
        let run = ciRun(42, branch: "TransactionsService", attempt: 2)
        let prompt = CIGuard.fixPrompt(run, log: "KeyError: 'since'", reviewRequest: GitHubActions(gh: "").reviewRequest)
        XCTAssertTrue(prompt.contains("KeyError: 'since'"))
        XCTAssertTrue(prompt.contains("git checkout -B ci-fix/TransactionsService-42 origin/TransactionsService"))
        XCTAssertTrue(prompt.contains("a PR into TransactionsService with `gh pr create`"))
        XCTAssertTrue(prompt.contains("Never push to main, master"))
        XCTAssertTrue(prompt.contains("never force-push"))

        // GitLab has merge requests, not PRs: a gh command would fail there.
        let gitlab = CIGuard.fixPrompt(run, log: "", reviewRequest: GitLabCI(glab: "").reviewRequest)
        XCTAssertTrue(gitlab.contains("`glab mr create --target-branch TransactionsService`"))
        XCTAssertFalse(gitlab.contains("gh pr"))
    }
}

private final class FakeCI: CIProvider, @unchecked Sendable {
    var runs: [CIRun] = []
    /// Per folder, where a test needs two repos apart; the rest see `runs`.
    var runsByPath: [String: [CIRun]] = [:]
    /// gh failing (no network, logged out).
    var offline = false
    var pipelines: [String: Pipeline] = [:]
    var reruns: [Int64] = []
    /// PR runs come from a branch of the repo itself, not a fork.
    var ownPullRequests = false
    func handles(_ project: Project) -> Bool { true }
    func runs(in path: String) async -> [CIRun]? { offline ? nil : runsByPath[path] ?? runs }
    func failedLog(_ run: CIRun, in path: String) async -> String { "KeyError: 'since'" }
    func rerunFailed(_ run: CIRun, in path: String) async -> Bool { reruns.append(run.id); return true }
    func isOwnPullRequest(_ run: CIRun, in path: String) async -> Bool { ownPullRequests }
    var reviewRequest: String { GitHubActions(gh: "").reviewRequest }
    func pipeline(runs: [CIRun], in path: String) async -> Pipeline? { pipelines[path] }
    func start(_ step: Pipeline.Step, of pipeline: Pipeline, in path: String) async -> String? { nil }
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
        store.ciProviders = [ci]
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

    /// A fork's PR is only reported, even with AUTOFIX; the user's own PR branch is rerun and fixed like a push.
    func testPullRequestFailureIsOnlyReportedEvenWithAutofix() async {
        await store.refreshCI()
        store.autofixProjectIds = [projectId]
        ci.runs = [ciRun(30, event: "pull_request"), ciRun(31, branch: "main", attempt: 2, event: "pull_request_target")]
        await store.refreshCI()
        XCTAssertTrue(ci.reruns.isEmpty && store.sessions.isEmpty)
        XCTAssertEqual(notices, ["CI failed", "CI failed"])

        ci.ownPullRequests = true
        ci.runs = [ciRun(32, branch: "own", event: "pull_request")]
        await store.refreshCI()
        XCTAssertEqual(ci.reruns, [32])
    }

    /// Autofix works in the background: the user keeps their session, Home and the keyboard.
    func testAutofixDoesNotTakeTheUserAwayFromTheirSession() async throws {
        await store.refreshCI()
        try store.createSession(projectId: projectId, model: nil, prompt: nil)
        let mine = store.selectedSessionId
        store.autofixProjectIds = [projectId]
        ci.runs = [ciRun(2, attempt: 2)]
        await store.refreshCI()
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.selectedSessionId, mine)
        let fix = try XCTUnwrap(store.sessions.first { $0.id != mine })
        XCTAssertNotNil(store.initialPrompts[fix.id!])                   // starts once login resolves (never in tests)

        store.isHomeShown = true
        ci.runs = [ciRun(3, branch: "other", attempt: 2)]
        await store.refreshCI()
        XCTAssertEqual(store.sessions.count, 3)
        XCTAssertTrue(store.isHomeShown)

        // FIX clicked by the user opens its session.
        await store.startCIFix(ciRun(4, branch: "third", attempt: 2), in: store.projects[0])
        XCTAssertEqual(store.sessions.count, 4)
        XCTAssertEqual(store.selectedSessionId, store.sessions.first { $0.worktreeName == "ci-fix-third-4" }?.id)
    }

    /// gh failing at launch (no network yet, logged out) isn't "no runs": history is recorded by the first pass that works.
    func testOfflineLaunchDoesNotActOnHistory() async {
        store.autofixProjectIds = [projectId]
        ci.offline = true
        ci.runs = [ciRun(1, minutesAgo: 600), ciRun(2, branch: "old", attempt: 2, minutesAgo: 900)]
        await store.refreshCI()
        ci.offline = false
        await store.refreshCI()
        XCTAssertTrue(ci.reruns.isEmpty && notices.isEmpty && store.sessions.isEmpty)

        ci.runs = [ciRun(3)]
        await store.refreshCI()
        XCTAssertEqual(ci.reruns, [3])
    }

    func testProjectAddedLaterStartsFromItsHistory() async throws {
        await store.refreshCI()
        let first = projectId
        let repo = try makeTempRepo(remote: "git@github.com:me/other.git")
        try git(["commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        try store.addProject(at: repo)
        let added = try XCTUnwrap(store.projects.first { $0.id != first })
        ci.runsByPath[added.path] = [ciRun(30, minutesAgo: 600)]
        await store.refreshCI()
        XCTAssertTrue(notices.isEmpty)
    }

    /// A repo no longer polled (its session closed mid-deploy) can't keep CI polled every 15 s for good.
    func testClosedSessionsRepoNoLongerCountsAsRunning() async throws {
        let other = try makeTempRepo(remote: "git@github.com:me/other.git")
        try git(["commit", "-q", "--allow-empty", "-m", "init"], in: other)
        ci.pipelines[other.path] = Pipeline(branch: "main", sha: "abc", steps: [.init(name: "Deploy", state: .running)])
        try store.createSession(projectId: projectId, model: nil, prompt: nil, extraDirs: [other.path])
        await store.refreshCI()
        XCTAssertNotNil(store.repoCI[other.path])
        XCTAssertTrue(store.isCIRunning)

        store.closeSession(store.sessions[0].id!)
        await store.refreshCI()
        XCTAssertNil(store.repoCI[other.path])
        XCTAssertFalse(store.isCIRunning)
    }
}

final class PipelineTests: XCTestCase {
    private func run(_ id: Int64, _ workflow: String, event: String, sha: String, branch: String = "master",
                     conclusion: String? = "success", status: String = "completed", minute: Int) -> CIRun {
        CIRun(databaseId: id, workflowName: workflow, headBranch: branch, headSha: sha, status: status, conclusion: conclusion,
              createdAt: Date(timeIntervalSince1970: Double(minute) * 60), attempt: 1, url: "u\(id)", event: event)
    }

    private let workflows = [GitHubActions.Workflow(name: "CI", path: ".github/workflows/ci.yml", state: "active"),
                             GitHubActions.Workflow(name: "Build & Push", path: ".github/workflows/build.yml", state: "active"),
                             GitHubActions.Workflow(name: "Deploy", path: ".github/workflows/deploy.yml", state: "active")]

    /// taxinet, 2026-09-23: CI (push) → Build & Push (workflow_run) on the same sha; Deploy is dispatch-only.
    func testGitHubChainIsTheLatestPushedCommitThenDeploy() throws {
        let runs = [run(1, "CI", event: "push", sha: "old", minute: 0),
                    run(2, "Build & Push", event: "workflow_run", sha: "old", minute: 5),
                    run(3, "CI", event: "push", sha: "new", minute: 10),
                    run(4, "Build & Push", event: "workflow_run", sha: "new", conclusion: nil, status: "in_progress", minute: 15),
                    run(5, "CI", event: "pull_request", sha: "pr", branch: "feat/x", conclusion: "failure", minute: 20)]
        let pipeline = try XCTUnwrap(GitHubActions.pipeline(runs: runs, workflows: workflows, branch: "master"))
        XCTAssertEqual(pipeline.sha, "new")
        XCTAssertEqual(pipeline.steps.map(\.name), ["CI", "Build & Push", "Deploy"])
        XCTAssertEqual(pipeline.steps.map(\.state), [.passed, .running, .manual])
        XCTAssertEqual(pipeline.steps[2].trigger, ".github/workflows/deploy.yml")
        XCTAssertNil(pipeline.steps[1].trigger)                       // "Push" in the name isn't a deploy button
        XCTAssertFalse(pipeline.canStart(pipeline.steps[2]))          // build still running
    }

    func testDeployOpensWhenEverythingBeforePassedAndCanBeRepeated() throws {
        let runs = [run(1, "CI", event: "push", sha: "s", minute: 0),
                    run(2, "Build & Push", event: "workflow_run", sha: "s", minute: 5),
                    run(3, "Deploy", event: "workflow_dispatch", sha: "s", minute: 9)]
        let pipeline = try XCTUnwrap(GitHubActions.pipeline(runs: runs, workflows: workflows, branch: "master"))
        XCTAssertEqual(pipeline.steps.map(\.state), [.passed, .passed, .passed])
        XCTAssertTrue(pipeline.canStart(pipeline.steps[2]))

        let red = [run(1, "CI", event: "push", sha: "t", conclusion: "failure", minute: 20),
                   run(2, "Build & Push", event: "workflow_run", sha: "t", conclusion: "skipped", minute: 21)]
        let blocked = try XCTUnwrap(GitHubActions.pipeline(runs: red, workflows: workflows, branch: "master"))
        XCTAssertEqual(blocked.steps.map(\.state), [.failed, .skipped, .manual])
        XCTAssertFalse(blocked.canStart(blocked.steps[2]))
    }

    /// A deploy held by a protected environment is approved on GitHub: Run would only queue another deploy.
    func testDeployWaitingForApprovalIsNotRunnable() throws {
        let runs = [run(1, "CI", event: "push", sha: "s", minute: 0),
                    run(2, "Build & Push", event: "workflow_run", sha: "s", minute: 5),
                    run(3, "Deploy", event: "workflow_dispatch", sha: "s", conclusion: nil, status: "waiting", minute: 9)]
        let pipeline = try XCTUnwrap(GitHubActions.pipeline(runs: runs, workflows: workflows, branch: "master"))
        XCTAssertEqual(pipeline.steps.map(\.state), [.passed, .passed, .manual])
        XCTAssertNil(pipeline.steps[2].trigger)
        XCTAssertFalse(pipeline.canStart(pipeline.steps[2]))
        XCTAssertEqual(pipeline.summary.text, "Deploy waits for someone's approval on the CI's site.")
        XCTAssertTrue(pipeline.summary.needsYou)
    }

    /// alva-backend's .gitlab-ci.yml: build → test (test + lint) → release → deploy (manual on master).
    func testGitLabStagesInOrderWithManualDeploy() {
        func job(_ id: Int64, _ name: String, _ stage: String, _ status: String, allowFailure: Bool = false) -> GitLabCI.APIJob {
            GitLabCI.APIJob(id: id, name: name, stage: stage, status: status, web_url: "j\(id)", allow_failure: allowFailure)
        }
        let jobs = [job(15, "deploy", "deploy", "manual"), job(14, "release", "release", "success"),
                    job(13, "lint", "test", "failed", allowFailure: true), job(12, "test", "test", "success"),
                    job(11, "build", "build", "success")]
        let steps = GitLabCI.steps(jobs, url: "p")
        XCTAssertEqual(steps.map(\.name), ["build", "test", "release", "deploy"])
        XCTAssertEqual(steps.map(\.state), [.passed, .passed, .passed, .manual])
        XCTAssertEqual(steps[3].trigger, "15")
        XCTAssertTrue(Pipeline(branch: "master", sha: "s", steps: steps).canStart(steps[3]))

        let running = GitLabCI.steps([job(22, "test", "test", "created"), job(21, "build", "build", "running")], url: "p")
        XCTAssertEqual(running.map(\.state), [.running, .pending])
    }

    /// alva-backend, 2026-09-23: every job failed with ci_quota_exceeded — nothing ran, so nothing to fix.
    func testOutOfCIMinutesIsReportedNeverRerunOrFixed() {
        var quota = CIRun(databaseId: 1, workflowName: "Pipeline", headBranch: "feature", headSha: "s", status: "completed",
                          conclusion: "failure", createdAt: .now, attempt: 2, url: "u", failureReason: "ci_quota_exceeded")
        XCTAssertEqual(CIGuard.action(for: quota, fixAttempts: 0, autofix: true), .reportInfra)
        quota.failureReason = "script_failure"
        XCTAssertEqual(CIGuard.action(for: quota, fixAttempts: 0, autofix: true), .fix)
    }

    /// A GitLab retry keeps the pipeline id: the retried jobs' copies make it a second attempt.
    func testRetriedGitLabPipelineCountsAsSecondAttempt() {
        func job(_ id: Int64, _ name: String, _ status: String, reason: String? = nil) -> GitLabCI.APIJob {
            GitLabCI.APIJob(id: id, name: name, stage: "test", status: status, web_url: "j\(id)", allow_failure: false,
                            failure_reason: reason)
        }
        XCTAssertEqual(GitLabCI.attempt([job(1, "build", "success"), job(2, "test", "failed")]), 1)
        XCTAssertEqual(GitLabCI.attempt([job(2, "test", "failed"), job(5, "test", "failed")]), 2)
        XCTAssertEqual(GitLabCI.attempt([job(2, "a", "failed"), job(5, "a", "success"), job(6, "b", "failed")]), 2)
        // Retried again and b failed again: a third attempt, not the already-handled second one.
        XCTAssertEqual(GitLabCI.attempt([job(2, "a", "failed"), job(5, "a", "success"), job(3, "b", "failed"), job(6, "b", "failed")]), 3)
        // Only a job's latest copy says why: a's stale quota failure mustn't make b's real one "CI didn't run".
        XCTAssertEqual(GitLabCI.failureReason([job(3, "a", "failed", reason: "ci_quota_exceeded"), job(5, "a", "success"),
                                               job(2, "b", "failed", reason: "script_failure")]), "script_failure")
        let retried = CIRun(databaseId: 7, workflowName: "Pipeline", headBranch: "feature", headSha: "s", status: "completed",
                            conclusion: "failure", createdAt: .now,
                            attempt: GitLabCI.attempt([job(2, "test", "failed"), job(5, "test", "failed")]), url: "u")
        XCTAssertEqual(CIGuard.action(for: retried, fixAttempts: 0, autofix: true), .fix)    // not another rerun
    }

    func testGitLabPipelineDatesWithMilliseconds() throws {
        let json = #"[{"id":7,"sha":"abc","ref":"master","status":"manual","source":"push","created_at":"2026-09-23T14:30:54.123Z","web_url":"w"}]"#
        let run = try XCTUnwrap(GitLabCI.decoder.decode([GitLabCI.APIPipeline].self, from: Data(json.utf8)).first?.run)
        XCTAssertFalse(run.failed || run.isRunning)                    // waiting for a manual deploy isn't a failure
        XCTAssertEqual(run.headBranch, "master")
    }
}
