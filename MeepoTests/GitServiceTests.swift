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
