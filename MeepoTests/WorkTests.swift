import GRDB
import XCTest
@testable import Meepo

/// A shared bare remote, the user's clone and a teammate's clone — all in the temp folder.
private struct Remote {
    let bare: URL, mine: URL, theirs: URL

    init() throws {
        let tmp = FileManager.default.temporaryDirectory
        bare = tmp.appending(path: "work-\(UUID().uuidString).git")
        try git(["init", "-q", "--bare", "-b", "main", bare.path], in: tmp)
        let seed = try makeTempRepo()
        try git(["checkout", "-q", "-B", "main"], in: seed)
        try git(["commit", "-q", "--allow-empty", "-m", "base"], in: seed)
        try git(["push", "-q", bare.path, "main"], in: seed)
        mine = tmp.appending(path: "mine-\(UUID().uuidString)")
        theirs = tmp.appending(path: "theirs-\(UUID().uuidString)")
        try git(["clone", "-q", bare.path, mine.path], in: tmp)
        try git(["clone", "-q", bare.path, theirs.path], in: tmp)
    }

    func commit(_ message: String, file: String, in repo: URL, as author: String? = nil) throws {
        try "\(message)\n".write(to: repo.appending(path: file), atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        try git((author.map { ["-c", "user.name=\($0)", "-c", "user.email=\($0)@team"] } ?? []) + ["commit", "-q", "-m", message], in: repo)
    }

    func sha(_ rev: String, in repo: URL) -> String { GitService.output(["rev-parse", rev], in: repo.path) ?? "" }

    func read() -> Work.Repo? { Work.read(name: "app", path: mine.path, since: Date(timeIntervalSince1970: 0)) }
}

final class WorkTests: XCTestCase {
    /// commit → push → a teammate pushes, we fetch → commit → push: two units, and the teammate's commit is in neither.
    func testAPushSendsOnlyItsOwnCommits() throws {
        let remote = try Remote()
        try remote.commit("feat(loans): правка займа", file: "loans.go", in: remote.mine)
        try git(["push", "-q"], in: remote.mine)
        try git(["pull", "-q", "--rebase"], in: remote.theirs)
        try remote.commit("fix: teammate's fix", file: "api.go", in: remote.theirs, as: "Rustem")
        try git(["push", "-q"], in: remote.theirs)
        try git(["fetch", "-q"], in: remote.mine)
        XCTAssertEqual(GitService.output(["log", "-1", "--format=%s", "origin/main"], in: remote.mine.path), "fix: teammate's fix")
        try git(["pull", "-q", "--rebase"], in: remote.mine)
        try remote.commit("feat(loans): импорт графика из Excel", file: "import.go", in: remote.mine)
        try git(["push", "-q"], in: remote.mine)

        let repo = try XCTUnwrap(remote.read())
        XCTAssertEqual(repo.host, "origin", "a remote that isn't GitHub or GitLab goes by its name")
        XCTAssertEqual(repo.sends.map { $0.commits.map(\.subject) }, [["feat(loans): правка займа"], ["feat(loans): импорт графика из Excel"]])
        XCTAssertFalse(repo.sends.flatMap(\.commits).contains { $0.subject == "fix: teammate's fix" })
        XCTAssertEqual(repo.sends.last?.files, 1, "only the file this push sent")
        XCTAssertTrue(repo.unsent.isEmpty && repo.uncommitted.isEmpty)
        XCTAssertEqual(repo.sends.last?.title, "Импорт графика из Excel")
    }

    /// After a force push the range starts at the common ancestor, not at the commit it replaced.
    func testAForcePushStartsAtTheCommonAncestor() throws {
        let remote = try Remote()
        try remote.commit("feat: first", file: "a.txt", in: remote.mine)
        try git(["push", "-q"], in: remote.mine)
        let base = remote.sha("HEAD", in: remote.mine)
        try remote.commit("feat: draft", file: "b.txt", in: remote.mine)
        try git(["push", "-q"], in: remote.mine)
        try "final\n".write(to: remote.mine.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        try git(["commit", "-q", "-a", "--amend", "-m", "feat: final"], in: remote.mine)
        try git(["push", "-q", "--force"], in: remote.mine)

        let forced = try XCTUnwrap(remote.read()?.sends.last)
        XCTAssertEqual(forced.from, base, "the ancestor both versions share")
        XCTAssertEqual(forced.commits.map(\.subject), ["feat: final"])
        XCTAssertEqual(forced.files, 1)
    }

    /// A new branch's first push: only what the remote didn't have, not the whole history.
    func testABranchsFirstPushIsItsOwnCommits() throws {
        let remote = try Remote()
        try git(["checkout", "-q", "-b", "feature"], in: remote.mine)
        try remote.commit("feat: on the branch", file: "f.txt", in: remote.mine)
        try git(["push", "-q", "-u", "origin", "feature"], in: remote.mine)
        let repo = try XCTUnwrap(remote.read())
        XCTAssertEqual(repo.upstream, "origin/feature")
        XCTAssertEqual(repo.sends.map { $0.commits.map(\.subject) }, [["feat: on the branch"]])
    }

    /// The branch was merged into main (and a teammate started a branch from it) after its first push: that push
    /// still sent its commit. Other branches count as they were at the push, not as they are now.
    func testABranchMergedSinceKeepsItsFirstPush() throws {
        let remote = try Remote()
        try git(["checkout", "-q", "-b", "feature"], in: remote.mine)
        try remote.commit("feat: on the branch", file: "f.txt", in: remote.mine)
        try git(["push", "-q", "-u", "origin", "feature"], in: remote.mine)
        try git(["fetch", "-q"], in: remote.theirs)
        try git(["-c", "user.name=Rustem", "-c", "user.email=r@team", "merge", "-q", "--no-ff", "-m", "Merge feature", "origin/feature"],
                in: remote.theirs)
        try git(["push", "-q", "origin", "main"], in: remote.theirs)
        try git(["push", "-q", "origin", "origin/feature:refs/heads/followup"], in: remote.theirs)
        // Ten minutes later, as reflogs count time (the whole test runs within a second).
        try gitAt(Int(Date.now.timeIntervalSince1970) + 600, ["fetch", "-q"], in: remote.mine)
        XCTAssertEqual(GitService.output(["log", "-1", "--format=%s", "origin/main"], in: remote.mine.path), "Merge feature")

        let repo = try XCTUnwrap(remote.read())
        XCTAssertEqual(repo.sends.map { $0.commits.map(\.subject) }, [["feat: on the branch"]])
        XCTAssertEqual(repo.sends.first?.files, 1)
    }

    /// meepo's own Push button leaves the same record: it's a unit too.
    func testPushFromMeepoIsAUnit() throws {
        let remote = try Remote()
        try remote.commit("feat: from the button", file: "x.txt", in: remote.mine)
        let before = try XCTUnwrap(remote.read())
        XCTAssertEqual(before.unsent.map(\.subject), ["feat: from the button"])
        XCTAssertEqual(Work.pending([before]), ["1 commit not sent"])
        XCTAssertNil(GitPanel.push(GitPanel.snapshot(in: remote.mine.path), in: remote.mine.path))
        let after = try XCTUnwrap(remote.read())
        XCTAssertEqual(after.sends.last?.commits.map(\.subject), ["feat: from the button"])
        XCTAssertTrue(after.unsent.isEmpty)
    }

    /// The branch was merged and deleted on the remote, then `fetch --prune`: status still names the upstream
    /// ("[gone]"), but it's not there — the commits are units again and the branch reads as not on the remote.
    func testAGoneUpstreamIsNoUpstream() throws {
        let remote = try Remote()
        try git(["checkout", "-q", "-b", "feature"], in: remote.mine)
        try remote.commit("feat: on the branch", file: "f.txt", in: remote.mine)
        try git(["push", "-q", "-u", "origin", "feature"], in: remote.mine)
        try git(["push", "-q", "origin", "--delete", "feature"], in: remote.theirs)
        try git(["fetch", "-q", "--prune"], in: remote.mine)
        XCTAssertTrue(GitService.output(["status", "-b", "--porcelain"], in: remote.mine.path)?.contains("[gone]") == true)

        let repo = try XCTUnwrap(remote.read())
        XCTAssertNil(repo.upstream)
        XCTAssertTrue(Work.units(repo, runs: []).contains { $0.commits(in: repo).map(\.subject) == ["feat: on the branch"] },
                      "the commit is still there as a unit")
        XCTAssertEqual(Work.pending([repo]), ["Branch not on origin yet"])
    }

    /// A fork: pulls from origin, pushes to its own remote. What's sent and what isn't follow the push remote.
    func testAForkCountsWhereItPushes() throws {
        let remote = try Remote()
        let fork = FileManager.default.temporaryDirectory.appending(path: "fork-\(UUID().uuidString).git")
        try git(["init", "-q", "--bare", "-b", "main", fork.path], in: remote.mine)
        try git(["remote", "add", "fork", fork.path], in: remote.mine)
        try git(["config", "remote.pushDefault", "fork"], in: remote.mine)
        try git(["config", "push.default", "current"], in: remote.mine)
        try remote.commit("feat: in my fork", file: "f.txt", in: remote.mine)
        try git(["push", "-q"], in: remote.mine)

        let repo = try XCTUnwrap(remote.read())
        XCTAssertEqual(repo.upstream, "fork/main")
        XCTAssertEqual(repo.host, "fork")
        XCTAssertTrue(repo.unsent.isEmpty, "sent to the fork, even though origin doesn't have it")
        XCTAssertEqual(repo.sends.last?.commits.map(\.subject), ["feat: in my fork"])
    }

    /// A detached HEAD (a rebase stops on one) isn't a branch waiting to be published.
    func testADetachedHeadIsNotABranch() throws {
        let remote = try Remote()
        try remote.commit("feat: one", file: "a.txt", in: remote.mine)
        try git(["checkout", "-q", "--detach"], in: remote.mine)
        let repo = try XCTUnwrap(remote.read())
        XCTAssertEqual(repo.branch, "HEAD")
        XCTAssertNil(repo.upstream)
        XCTAssertEqual(Work.pending([repo]), [])
        XCTAssertNil(Work.nextStep(repo))
    }

    /// Without an upstream each commit is a unit; what isn't committed is NOW.
    func testWithoutAnUpstreamACommitIsTheUnit() throws {
        let repo = try makeTempRepo()
        try git(["commit", "-q", "--allow-empty", "-m", "feat: one"], in: repo)
        try git(["commit", "-q", "--allow-empty", "-m", "chore: two"], in: repo)
        try "wip".write(to: repo.appending(path: "wip.txt"), atomically: true, encoding: .utf8)
        let read = try XCTUnwrap(Work.read(name: "r", path: repo.path, since: Date(timeIntervalSince1970: 0)))
        XCTAssertNil(read.upstream)
        let units = Work.units(read, runs: [])
        XCTAssertEqual(units.map(\.id).first, "now:" + repo.path)
        XCTAssertEqual(units.dropFirst().map { $0.commits(in: read).map(\.subject) }, [["chore: two"], ["feat: one"]])
        XCTAssertEqual(Work.pending([read]), ["1 file not committed"], "nothing to send to: no remote")
    }

    /// A folder of two repos has a NOW for each: Today lists both, so they can't share an id.
    func testEachReposNowIsItsOwn() {
        let api = Work.Repo(name: "api", path: "/p/api", upstream: "origin/main", head: "a", uncommitted: ["x.go"])
        let web = Work.Repo(name: "web", path: "/p/web", upstream: "origin/main", head: "b", uncommitted: ["y.tsx"])
        XCTAssertNotEqual(Work.units(api, runs: []).first?.id, Work.units(web, runs: []).first?.id)
    }

    /// Requests go to the push they led to; the ones after the last push are NOW; older ones drop out.
    func testRequestsBelongToThePushTheyLedTo() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        func run(_ request: String, _ minute: Double) -> Run {
            Run(sessionId: 1, startedAt: t0 + minute * 60, endedAt: t0 + minute * 60 + 30, request: request, files: [], reply: "ok")
        }
        let first = Work.Send(at: t0 + 600, from: "a", to: "b", after: t0 + 60, commits: [], files: 1)
        let second = Work.Send(at: t0 + 1800, from: "b", to: "c", after: t0 + 600, commits: [], files: 2)
        let repo = Work.Repo(name: "r", path: "/r", upstream: "origin/main", sends: [first, second])
        let units = Work.units(repo, runs: [run("before the week", 0), run("a", 5), run("commit and push", 9.9),
                                            run("b", 20), run("after", 40)])
        XCTAssertEqual(units.map(\.id), ["now:/r", "sent:c", "sent:b"])
        XCTAssertEqual(units.map { $0.runs.map(\.request) }, [["after"], ["b"], ["a", "commit and push"]])
        XCTAssertEqual(Work.units(Work.Repo(name: "r", path: "/r", upstream: "origin/main", sends: [first]), runs: []).map(\.id),
                       ["sent:b"], "nothing unsent, nothing asked since: no NOW")
    }

    /// A folder holding several repos: a request goes with the repo whose files it edited, never with both.
    func testInAFolderOfReposARequestGoesWithItsFiles() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let (api, web) = (Work.Repo(name: "api", path: "/p/api"), Work.Repo(name: "web", path: "/p/web"))
        let runs = [Run(sessionId: 1, startedAt: t0, request: "fix the web form", files: ["/p/web/form.tsx"]),
                    Run(sessionId: 1, startedAt: t0 + 60, request: "what is failing?", files: [])]
        XCTAssertEqual(Work.runs(runs, for: web, in: [api, web]).map(\.request), ["fix the web form"])
        XCTAssertEqual(Work.runs(runs, for: api, in: [api, web]).map(\.request), ["what is failing?"])
        XCTAssertEqual(Work.runs(runs, for: api, in: [api]).count, 2, "one repo: every request is its own")
    }

    /// NOW's explanation is kept under what isn't sent: a new request or file makes it a new one.
    func testNowsKeyFollowsWhatIsntSent() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        var repo = Work.Repo(name: "r", path: "/r", upstream: "origin/main", head: "abc", uncommitted: ["a.go"])
        let before = Work.units(repo, runs: [])[0].key
        repo.uncommitted.append("b.go")
        XCTAssertNotEqual(Work.units(repo, runs: [])[0].key, before)
        XCTAssertNotEqual(Work.units(repo, runs: [Run(sessionId: 1, startedAt: t0, request: "x", files: [])])[0].key, before)
        XCTAssertEqual(Work.units(repo, runs: [])[0].key, Work.units(repo, runs: [])[0].key, "stable across reads")
    }

    func testCommitsReadForPeople() {
        let commit = { Work.Commit(sha: "1", subject: $0, date: .now) }
        XCTAssertTrue(commit("feat(loans): импорт").isNotable)
        XCTAssertTrue(commit("fix!: crash").isNotable)
        XCTAssertFalse(commit("chore(mobile): 1.7.8+91").isNotable, "shown dim, not hidden")
        XCTAssertEqual(commit("feat(loans): импорт графика из Excel").title, "Импорт графика из Excel")
        XCTAssertEqual(commit("Add a button").title, "Add a button")
        XCTAssertEqual(Work.host(of: "git@github.com:acme/app.git"), "GitHub")
        XCTAssertEqual(Work.host(of: "https://gitlab.example.com/a/b"), "GitLab")
        XCTAssertNil(Work.host(of: "/tmp/remote.git"))
    }

    func testReflogLinesCarryTheirTime() {
        let entries = Work.parseReflog("""
            0000000000000000000000000000000000000000 abc Azamat Bigali <a@b.c> 1790502357 +0500\tupdate by push
            bad line
            abc def Rustem <r@t> 1790500000 -0100\tfetch: fast-forward
            """)
        XCTAssertEqual(entries, [Work.ReflogEntry(old: "0000000000000000000000000000000000000000", new: "abc",
                                                  date: Date(timeIntervalSince1970: 1_790_502_357), subject: "update by push"),
                                 Work.ReflogEntry(old: "abc", new: "def", date: Date(timeIntervalSince1970: 1_790_500_000),
                                                  subject: "fetch: fast-forward")])
    }

    /// A card says whether it needs you before anything else, then how the last request ended.
    func testACardsMainLine() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let permission = EventStory.Line(id: 1, icon: "", title: "Asked your permission: “Bash: git push”", detail: "Bash: git push",
                                         date: t0, file: nil, isRunning: false, isFailure: false, needsYou: true)
        XCTAssertEqual(Work.cardLine(status: .waitingPermission, run: nil, last: permission).label, "Needs permission")
        let asked = Run(sessionId: 1, startedAt: t0, endedAt: t0 + 60, request: "импорт", files: [], reply: "Готово.\n\nЗакоммитить?")
        XCTAssertEqual(Work.cardLine(status: .waitingInput, run: asked, last: nil).text, "Закоммитить?")
        let step = EventStory.Line(id: 2, icon: "", title: "Ran npm test…", detail: nil, date: t0, file: nil,
                                   isRunning: true, isFailure: false, needsYou: false)
        XCTAssertEqual(Work.cardLine(status: .thinking, run: nil, last: step).label, "Now")
        let done = Run(sessionId: 1, startedAt: t0, endedAt: t0 + 60, request: "fix the total", files: [], reply: "Fixed: totals include delivery.")
        XCTAssertEqual(Work.cardLine(status: .waitingInput, run: done, last: nil).text, "“fix the total” → Fixed: totals include delivery.")
        // Working again after it asked (a helper's report woke it): what it does now, not the old question.
        let now = Work.cardLine(status: .thinking, run: asked, last: step)
        XCTAssertEqual(now.label, "Now")
        XCTAssertFalse(now.needsYou)
    }

    /// Only a Bash step that may commit or push reads git again.
    func testWhichStepsTouchGit() {
        func bash(_ command: String) -> HookPayload { HookPayload(event: "PostToolUse", claudeSessionId: "s", toolName: "Bash", toolTarget: command) }
        XCTAssertTrue(AppStore.touchesGit(bash("cd x && git commit -m y && git push")))
        XCTAssertTrue(AppStore.touchesGit(bash("gh pr create --fill")))
        XCTAssertFalse(AppStore.touchesGit(bash("git status --short")))
        XCTAssertFalse(AppStore.touchesGit(HookPayload(event: "PostToolUse", claudeSessionId: "s", toolName: "Edit", toolTarget: "/a/git push.md")))
    }

    // MARK: Explain for users

    /// The shape `claude -p --json-schema` returned in a real run on 2.1.282.
    func testSummaryDecodesTheStructuredAnswer() throws {
        let json = #"{"headline":"Водитель может вернуть оплату","changes":[{"kind":"new","what":"Кнопка «Возврат»","where":"Driver app → Payment"}],"check":["Возврат больше 50 000 ₸ ждёт менеджера?"],"how_to_try":"Откройте экран оплаты"}"#
        let summary = try JSONDecoder().decode(ProductSummary.self, from: Data(json.utf8))
        XCTAssertEqual(summary.changes.first?.where_, "Driver app → Payment")
        XCTAssertEqual(summary.changes.first?.section, "Driver app", "grouped by the product's section")
        XCTAssertEqual(summary.check.count, 1)
        XCTAssertEqual(summary.howToTry, "Откройте экран оплаты")
    }

    func testTheSchemaIsValidJSON() throws {
        let schema = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(Work.schema.utf8)) as? [String: Any])
        XCTAssertEqual((schema["required"] as? [String])?.sorted(), ["changes", "check", "headline", "how_to_try"])
    }

    /// The material is the user's requests, Claude's answers and the commits — a diff only for what isn't sent.
    func testThePromptCarriesRequestsAnswersAndCommits() {
        let run = Run(sessionId: 1, startedAt: .now, endedAt: .now, request: "давай импорт графика из Excel", files: [],
                      reply: "Импорт графика займа из Excel готов.")
        let sent = Work.prompt(runs: [run], commits: "- feat(loans): импорт графика", diff: nil, language: "English")
        XCTAssertTrue(sent.contains("Asked: давай импорт графика из Excel") && sent.contains("Claude answered: Импорт графика займа"))
        XCTAssertTrue(sent.contains("<commits>\n- feat(loans): импорт графика"))
        XCTAssertFalse(sent.contains("<diff>"))
        XCTAssertTrue(Work.prompt(runs: [], commits: "", diff: "+ a", language: "English").contains("<diff>\n+ a"))
    }

    /// What isn't sent yet is explained from its diff, uncommitted files included.
    func testNowsMaterialIsTheDiff() throws {
        let remote = try Remote()
        try remote.commit("feat: unsent", file: "u.txt", in: remote.mine)
        try "new\n".write(to: remote.mine.appending(path: "new.txt"), atomically: true, encoding: .utf8)
        let repo = try XCTUnwrap(remote.read())
        let now = try XCTUnwrap(Work.units(repo, runs: []).first)
        let material = Work.material(of: now, in: repo)
        XCTAssertTrue(material.commits.contains("feat: unsent"))
        XCTAssertTrue(material.diff?.contains("u.txt") == true && material.diff?.contains("new.txt") == true)
    }
}

@MainActor
final class WorkStoreTests: XCTestCase {
    /// The store keeps each folder's pushes, requests and explanations; views only read them.
    func testTheStoreReadsAFoldersWork() async throws {
        let remote = try Remote()
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        try store.addProject(at: remote.mine)
        let project = store.projects[0]
        try store.createSession(projectId: project.id!, model: nil, prompt: nil)
        let session = store.sessions[0]
        store.handleHookEvent(HookPayload(event: "UserPromptSubmit", claudeSessionId: session.claudeSessionId,
                                          prompt: "закоммить и запушь"), sessionId: session.id!)
        store.handleHookEvent(HookPayload(event: "UserPromptSubmit", claudeSessionId: session.claudeSessionId,
                                          prompt: RunsTestsSamples.notification), sessionId: session.id!)
        try remote.commit("feat: sent", file: "s.txt", in: remote.mine)
        try git(["push", "-q"], in: remote.mine)
        let sha = remote.sha("HEAD", in: remote.mine)
        try await db.write { db in
            try db.execute(sql: "INSERT INTO workSummary (folder, unit, json, createdAt) VALUES (?, ?, ?, ?)", arguments: [
                project.path, "sent:" + sha, #"{"headline":"h","changes":[],"check":[],"how_to_try":""}"#, Date.now])
        }
        await store.refreshWork(project.path)

        let work = try XCTUnwrap(store.work[project.path])
        XCTAssertEqual(work.runs.map(\.request), ["закоммить и запушь"], "Claude Code's own turn isn't a request")
        XCTAssertEqual(work.repos.first?.sends.last?.id, "sent:" + sha)
        XCTAssertEqual(work.summaries["sent:" + sha]?.headline, "h")
        XCTAssertEqual(store.titles[session.id!], "закоммить и запушь")
    }

    /// The card's "needs you" line keeps what the session waits on: the Notification Claude Code sends ~6 s after
    /// a permission request ("Waiting for you") doesn't replace it.
    func testTheLastLineKeepsWhatItWaitsOn() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        try store.addProject(at: try makeTempRepo())
        try store.createSession(projectId: store.projects[0].id!, model: nil, prompt: nil)
        let session = store.sessions[0]
        store.handleHookEvent(HookPayload(event: "PermissionRequest", claudeSessionId: session.claudeSessionId,
                                          toolName: "Bash", toolTarget: "git push"), sessionId: session.id!)
        store.handleHookEvent(HookPayload(event: "Notification", claudeSessionId: session.claudeSessionId,
                                          notificationType: "permission_prompt", message: "Claude needs your permission to use Bash"),
                              sessionId: session.id!)
        XCTAssertEqual(store.lastLine[session.id!]?.detail, "Bash: git push")
        let line = Work.cardLine(status: store.sessions[0].status, run: nil, last: store.lastLine[session.id!])
        XCTAssertEqual(line.label, "Needs permission")
        XCTAssertEqual(line.text, "Bash: git push")
    }
}

/// git with the committer's time (and so the reflog's) set to `time`.
private func gitAt(_ time: Int, _ args: [String], in dir: URL) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/git")
    process.arguments = ["-C", dir.path] + args
    process.environment = ProcessInfo.processInfo.environment.merging(["GIT_COMMITTER_DATE": "@\(time) +0000"]) { $1 }
    try process.run()
    process.waitForExit()
}

/// Shared by the store test.
enum RunsTestsSamples {
    static let notification = "<task-notification>\n<task-id>b1</task-id>\n<summary>Background command \"Build\" completed</summary>\n</task-notification>"
}
