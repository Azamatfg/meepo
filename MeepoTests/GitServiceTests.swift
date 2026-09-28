import GRDB
import XCTest
@testable import Meepo

/// Creates a throwaway git repo at its real path: git reports /private/var/..., and
/// Foundation's resolvingSymlinksInPath() would strip /private again, so use realpath(3).
func makeTempRepo(remote: String? = nil) throws -> URL {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "meepo-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let dir = URL(filePath: String(cString: realpath(tmp.path, nil)))
    try git(["init", "-q", "-b", "trunk"], in: dir)
    if let remote { try git(["remote", "add", "origin", remote], in: dir) }
    return dir
}

/// A store that never touches the user's settings, ~/.claude or ~/.meepo (tests run inside the app).
@MainActor
func makeIsolatedStore(db: DatabaseQueue) -> AppStore {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "store-\(UUID().uuidString)")
    return AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "settings.json"), meepoHome: tmp),
                    usageRoot: tmp, defaults: UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!)
}

func git(_ args: [String], in dir: URL) throws {
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/git")
    p.arguments = ["-C", dir.path] + args
    try p.run()
    p.waitUntilExit()
}

final class GitServiceTests: XCTestCase {
    func testReadsOriginRemoteAndBranch() throws {
        let repo = try makeTempRepo(remote: "git@github.com:me/app.git")
        XCTAssertEqual(GitService.remoteURL(in: repo.path), "git@github.com:me/app.git")
        XCTAssertEqual(GitService.currentBranch(in: repo.path), "trunk")
    }

    func testRepoWithoutRemoteReturnsNil() throws {
        let repo = try makeTempRepo()
        XCTAssertNil(GitService.remoteURL(in: repo.path))
    }

    func testSubfolderResolvesToRepositoryRoot() throws {
        let repo = try makeTempRepo()
        let sub = repo.appending(path: "src/deep")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertEqual(try GitService.repositoryRoot(of: sub.path), repo.path)
    }

    func testPlainFolderIsRejected() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "meepo-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertThrowsError(try GitService.repositoryRoot(of: dir.path)) {
            XCTAssertEqual($0 as? GitError, .notARepository(dir.path))
        }
    }

    /// The 10 s poll must not write the index back: that holds index.lock, and Claude's `git commit` would fail.
    func testUncommittedCheckLeavesTheIndexAlone() throws {
        let repo = try makeTempRepo()
        let file = repo.appending(path: "a.txt")
        try "a\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "a.txt"], in: repo)
        try git(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-qm", "init"], in: repo)
        // Same content, newer mtime: a plain `git status` refreshes the stat data and rewrites the index.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(100)], ofItemAtPath: file.path)
        let index = repo.appending(path: ".git/index")
        let before = try Data(contentsOf: index)
        XCTAssertFalse(GitService.hasUncommittedChanges(in: repo.path))
        XCTAssertEqual(try Data(contentsOf: index), before)

        try "b\n".write(to: repo.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(GitService.hasUncommittedChanges(in: repo.path), "an untracked file is a change")
    }

    /// check-ignore never reports a tracked file, so the exclude line must not be added again on every call.
    func testIgnoreLocallyAddsATrackedFileOnce() throws {
        let repo = try makeTempRepo()
        try git(["config", "core.excludesFile", "/dev/null"], in: repo)   // the user's global excludes may already ignore it
        try FileManager.default.createDirectory(at: repo.appending(path: ".claude"), withIntermediateDirectories: true)
        try "{}".write(to: repo.appending(path: ".claude/settings.local.json"), atomically: true, encoding: .utf8)
        try git(["add", ".claude/settings.local.json"], in: repo)
        let backups = FileManager.default.temporaryDirectory.appending(path: "backups-\(UUID().uuidString)")

        GitService.ignoreLocally(".claude/settings.local.json", in: repo.path, backups: backups)
        GitService.ignoreLocally(".claude/settings.local.json", in: repo.path, backups: backups)
        let exclude = try String(contentsOf: repo.appending(path: ".git/info/exclude"), encoding: .utf8)
        XCTAssertEqual(exclude.split(separator: "\n").filter { $0 == ".claude/settings.local.json" }.count, 1)
        XCTAssertEqual(ChangeLog.entries(backups: backups).filter { $0.action == "Ignore .claude/settings.local.json" }.count, 1)
    }

    /// The day report: commits on local branches, not a fetched remote branch's or the stash's.
    func testTodaysCommitsAreLocalBranchesOnly() throws {
        let repo = try makeTempRepo()
        let id = ["-c", "user.name=T", "-c", "user.email=t@t"]
        try "a\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        try git(id + ["commit", "-qm", "my work"], in: repo)
        try git(["checkout", "-q", "-b", "teammate"], in: repo)
        try git(id + ["commit", "-q", "--allow-empty", "-m", "teammate work"], in: repo)
        try git(["update-ref", "refs/remotes/origin/feature", "HEAD"], in: repo)   // as a fetch leaves it
        try git(["checkout", "-q", "trunk"], in: repo)
        try git(["branch", "-q", "-D", "teammate"], in: repo)
        try "wip\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try git(id + ["stash", "push", "-q", "-m", "t"], in: repo)   // this temp repo's own stash

        let commits = GitService.commits(since: Calendar.current.startOfDay(for: .now), in: repo.path)
        XCTAssertTrue(commits.contains { $0.hasSuffix(" my work") }, "\(commits)")
        XCTAssertFalse(commits.contains { $0.hasSuffix(" teammate work") }, "\(commits)")
        XCTAssertFalse(commits.contains { $0.contains("index on") }, "\(commits)")
    }
}

@MainActor
final class AppStoreTests: XCTestCase {
    private func makeStore() throws -> AppStore {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        return makeIsolatedStore(db: db)
    }

    func testAddProjectStoresRootNameAndRemote() throws {
        let store = try makeStore()
        let repo = try makeTempRepo(remote: "https://github.com/me/app.git")
        try store.addProject(at: repo.appending(path: "."))
        XCTAssertEqual(store.projects.count, 1)
        XCTAssertEqual(store.projects[0].path, repo.path)
        XCTAssertEqual(store.projects[0].name, repo.lastPathComponent)
        XCTAssertEqual(store.projects[0].remote, "https://github.com/me/app.git")
    }

    func testAddingSameRepoViaSubfolderIsDuplicate() throws {
        let store = try makeStore()
        let repo = try makeTempRepo()
        let sub = repo.appending(path: "src")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try store.addProject(at: repo)
        XCTAssertThrowsError(try store.addProject(at: sub)) {
            XCTAssertEqual($0 as? AddProjectError, .alreadyAdded(repo.lastPathComponent))
        }
        XCTAssertEqual(store.projects.count, 1)
    }
}
