import GRDB
import XCTest
@testable import Meepo

final class ReposTests: XCTestCase {
    func testAFolderOfReposShowsEachOne() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "multi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["ocpp2.0", "ocpi", "e2e", "node_modules"] {
            try FileManager.default.createDirectory(at: folder.appending(path: name), withIntermediateDirectories: true)
        }
        for name in ["ocpi", "ocpp2.0", "node_modules"] { try git(["init", "-q"], in: folder.appending(path: name)) }
        XCTAssertEqual(Repos.find(in: folder.path).map(\.name), ["ocpi", "ocpp2.0"], "e2e isn't a repo; dependencies don't count")

        let repo = try makeTempRepo()
        XCTAssertEqual(Repos.find(in: repo.path).map(\.path), [repo.path], "a repo is just itself")
        let plain = FileManager.default.temporaryDirectory.appending(path: "plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertEqual(Repos.find(in: plain.path).map(\.path), [plain.path], "a plain folder still offers git init")
    }

    func testAddDirsComeFirstSoThePromptStaysAPrompt() {
        let args = ClaudeLauncher.claudeArguments(sessionId: "id", resume: false, model: nil, prompt: "fix it", addDirs: ["/a", "/b"])
        XCTAssertEqual(Array(args.prefix(4)), ["--add-dir", "/a", "/b", "--session-id"], "--add-dir takes several values")
        XCTAssertEqual(args.last, "fix it")
    }
}

@MainActor
final class LinkedProjectsTests: XCTestCase {
    func testSessionReposIncludeAlsoWorkInAndExplorerSeesNestedChanges() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "linked-\(UUID().uuidString)")
        let store = AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "s.json"), meepoHome: tmp),
                             usageRoot: tmp, defaults: UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!)
        let platform = tmp.appending(path: "charge-ev")
        try FileManager.default.createDirectory(at: platform.appending(path: "ocpi"), withIntermediateDirectories: true)
        try git(["init", "-q"], in: platform.appending(path: "ocpi"))
        try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"], in: platform.appending(path: "ocpi"))
        try "x".write(to: platform.appending(path: "ocpi/new.txt"), atomically: true, encoding: .utf8)
        try store.addProject(at: platform)
        let other = try makeTempRepo()
        try store.addProject(at: other)
        let platformProject = try XCTUnwrap(store.projects.first { $0.name == "charge-ev" })
        try store.createSession(projectId: platformProject.id!, model: nil, prompt: nil, extraDirs: [other.path])
        let session = try XCTUnwrap(store.sessions.last)
        XCTAssertEqual(session.extraDirs, [other.path])

        await store.refreshSourceControls(for: session)
        XCTAssertEqual(store.sessionRepos.map(\.name), ["ocpi", other.lastPathComponent])
        XCTAssertEqual(store.sessionRepos.last?.isLinked, true)
        let root = try XCTUnwrap(store.workdir(of: session))
        XCTAssertEqual(store.changes(under: root).map(\.path), ["ocpi/new.txt"], "the Explorer colors files inside nested repos")

        try store.replaceSession(session.id!)
        XCTAssertEqual(store.sessions.last?.extraDirs, [other.path], "a fresh session keeps where it also works")
    }
}
