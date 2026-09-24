import GRDB
import XCTest
@testable import Meepo

final class WorktreeLaunchTests: XCTestCase {
    func testFirstStartCreatesWorktreeThenRunsInsideIt() throws {
        let repo = try makeTempRepo()
        XCTAssertTrue(ClaudeLauncher.location(worktreeName: nil, projectPath: repo.path) == (repo.path, nil))
        // Not created yet: run in the repo and let `claude -w` create it (user's worktree settings/hooks apply).
        XCTAssertTrue(ClaudeLauncher.location(worktreeName: "login", projectPath: repo.path) == (repo.path, "login"))
        let path = ClaudeLauncher.worktreePath("login", projectPath: repo.path)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        // Exists: resume inside it (its transcript lives under that folder), never create twice.
        XCTAssertTrue(ClaudeLauncher.location(worktreeName: "login", projectPath: repo.path) == (path, nil))
    }

    func testWorktreeFlagAndSlug() {
        XCTAssertEqual(ClaudeLauncher.claudeArguments(sessionId: "id", resume: false, model: nil, worktree: "login", prompt: nil),
                       ["--session-id", "id", "--worktree", "login"])
        XCTAssertEqual(ClaudeLauncher.worktreeSlug("Login via Google!"), "login-via-google")
        XCTAssertEqual(ClaudeLauncher.worktreeSlug("  ??  "), "")
    }
}

final class PortsTests: XCTestCase {
    func testNextBaseSkipsTakenAndBusyBlocks() {
        XCTAssertEqual(Ports.nextBase(taken: [], listening: []), 20_000)
        XCTAssertEqual(Ports.nextBase(taken: [20_000], listening: []), 20_010)
        XCTAssertEqual(Ports.nextBase(taken: [20_000], listening: [20_013]), 20_020) // a dev server already on 20013
    }

    func testParsesLsofOutput() {
        let listen = "p501\ncnode\nn*:3000\nn[::1]:3000\np77\ncpostgres\nn127.0.0.1:5432\n"
        XCTAssertEqual(Ports.parseListen(listen).map { "\($0.port) \($0.pid) \($0.command)" },
                       ["3000 501 node", "3000 501 node", "5432 77 postgres"])
        XCTAssertEqual(Ports.parseCwd("p501\nfcwd\nn/Users/me/app/.claude/worktrees/login\np77\nfcwd\nn/\n"),
                       [501: "/Users/me/app/.claude/worktrees/login", 77: "/"])
    }
}

@MainActor
final class ParallelFeaturesTests: XCTestCase {
    private var store: AppStore!
    private var repo: URL!

    override func setUp() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "pf-\(UUID().uuidString)")
        store = AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "s.json"), meepoHome: tmp),
                         usageRoot: tmp, defaults: UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!)
        repo = try makeTempRepo()
        try git(["commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        try store.addProject(at: repo)
    }

    /// SPEC module 5 "done when": two features in one repo run in parallel without file or port conflicts.
    func testTwoFeaturesGetOwnFoldersBranchesAndPorts() throws {
        let projectId = store.projects[0].id!
        try store.createSession(projectId: projectId, model: nil, prompt: nil, worktree: "Login")
        try store.createSession(projectId: projectId, model: nil, prompt: nil, worktree: "Billing")
        let (a, b) = (store.sessions[0], store.sessions[1])
        XCTAssertEqual([a.branch, b.branch], ["worktree-login", "worktree-billing"])
        XCTAssertNotEqual(store.workdir(of: a), store.workdir(of: b))
        XCTAssertNotEqual(store.workdir(of: a), repo.path)
        XCTAssertNotEqual(a.portBase, b.portBase)
        XCTAssertGreaterThanOrEqual(abs(a.portBase! - b.portBase!), Ports.blockSize) // ranges don't overlap
        XCTAssertNotNil(a.worktreeBase)
        // .claude/worktrees stays out of `git status`, via the local exclude file.
        let status = Process()
        status.executableURL = URL(filePath: "/usr/bin/git")
        status.arguments = ["-C", repo.path, "check-ignore", "-q", ".claude/worktrees/login"]
        try status.run()
        status.waitUntilExit()
        XCTAssertEqual(status.terminationStatus, 0)
    }

    func testMergedWorktreeIsOfferedForRemovalAndRemoved() throws {
        try store.createSession(projectId: store.projects[0].id!, model: nil, prompt: nil, worktree: "login")
        let session = store.sessions[0]
        let path = store.workdir(of: session)!
        // What `claude -w login` does on first start.
        try git(["worktree", "add", "-q", "-b", "worktree-login", path], in: repo)

        store.refreshProjects()
        XCTAssertFalse(store.mergedWorktreeSessionIds.contains(session.id!)) // nothing done yet ≠ merged

        try git(["commit", "-q", "--allow-empty", "-m", "feature"], in: URL(filePath: path))
        store.refreshProjects()
        XCTAssertFalse(store.mergedWorktreeSessionIds.contains(session.id!)) // work not merged yet

        try git(["merge", "-q", "worktree-login"], in: repo)
        store.refreshProjects()
        XCTAssertTrue(store.mergedWorktreeSessionIds.contains(session.id!))

        store.removeWorktree(of: session.id!)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertNil(GitService.isMerged(branch: "worktree-login", startedAt: "", in: repo.path) ? "still there" : nil)
        XCTAssertTrue(store.sessions.isEmpty)
    }
}

@MainActor
final class ReplaceSessionTests: XCTestCase {
    /// "Start a new session and kill the old one": same folder, worktree, branch and ports; old one gone.
    func testNewSessionInsteadKeepsTheFolderAndDropsTheOld() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        let repo = try makeTempRepo()
        try git(["commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        try store.addProject(at: repo)
        try store.createSession(projectId: store.projects[0].id!, model: "opus", prompt: nil, worktree: "login")
        let old = store.sessions[0]

        try store.replaceSession(old.id!)
        XCTAssertEqual(store.sessions.count, 1)
        let fresh = store.sessions[0]
        XCTAssertNotEqual(fresh.id, old.id)
        XCTAssertNotEqual(fresh.claudeSessionId, old.claudeSessionId)          // a new conversation
        XCTAssertEqual(fresh.worktreeName, "login")
        XCTAssertEqual(fresh.branch, old.branch)
        XCTAssertEqual(fresh.portBase, old.portBase)
        XCTAssertEqual(fresh.model, "opus")
        XCTAssertEqual(store.selectedSessionId, fresh.id)
    }
}

@MainActor
final class RemoveProjectTests: XCTestCase {
    /// Out of Meepo, not off the disk: sessions go, the folder and the user's own hook stay as they were.
    func testRemoveClosesSessionsKeepsTheFolderAndRestoresHooks() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "rp-\(UUID().uuidString)")
        let bridge = BridgeInstaller(settingsURL: tmp.appending(path: "settings.json"), meepoHome: tmp)
        try bridge.install()
        let store = AppStore(db: db, bridge: bridge, usageRoot: tmp,
                             defaults: UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!)
        let repo = try makeTempRepo()
        let hooks = #"{"hooks":{"Notification":[{"hooks":[{"type":"command","command":"n.sh"}]}]}}"#
        try FileManager.default.createDirectory(at: repo.appending(path: ".claude"), withIntermediateDirectories: true)
        try hooks.write(to: repo.appending(path: ".claude/settings.local.json"), atomically: true, encoding: .utf8)
        try store.addProject(at: repo)                                   // guards the project's own hook
        try store.createSession(projectId: store.projects[0].id!, model: nil, prompt: nil)

        store.removeProject(store.projects[0].id!)
        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.path))
        XCTAssertEqual(try String(contentsOf: repo.appending(path: ".claude/settings.local.json"), encoding: .utf8), hooks)
    }
}
