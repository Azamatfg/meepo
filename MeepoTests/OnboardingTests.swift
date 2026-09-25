import GRDB
import XCTest
@testable import Meepo

final class GuidedSettingsTests: XCTestCase {
    func testGuidedSessionsExplainAndAskBeforeRiskyThings() throws {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(ClaudeLauncher.sessionSettings(effort: nil, guided: true)[1].utf8)) as? [String: Any])
        XCTAssertEqual(json["outputStyle"] as? String, "Explanatory")
        let ask = try XCTUnwrap((json["permissions"] as? [String: Any])?["ask"] as? [String])
        XCTAssertTrue(ask.contains("Bash(git push:*)"))
        XCTAssertTrue(ask.contains("Edit(**/.env*)"))
        XCTAssertNil((json["permissions"] as? [String: Any])?["allow"], "guided mode never allows anything new")
    }

    func testOthersGetNeither() throws {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(ClaudeLauncher.sessionSettings(effort: nil)[1].utf8)) as? [String: Any])
        XCTAssertNil(json["outputStyle"])
        XCTAssertNil(json["permissions"])
    }
}

@MainActor
final class NewProjectTests: XCTestCase {
    func testANewProjectIsAGitFolderInMeepo() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "np-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!
        let store = AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "s.json"), meepoHome: tmp),
                             usageRoot: tmp, defaults: defaults)
        let project = try XCTUnwrap(try store.createProject(named: "my-first-app", in: tmp))
        XCTAssertEqual(project.name, "my-first-app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appending(path: "my-first-app/.git").path))
        XCTAssertThrowsError(try store.createProject(named: "my-first-app", in: tmp), "never on top of an existing folder")
        XCTAssertThrowsError(try store.createProject(named: "  ", in: tmp))

        store.guidedMode = true
        let again = AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "s.json"), meepoHome: tmp),
                             usageRoot: tmp, defaults: defaults)
        XCTAssertTrue(again.guidedMode, "the choice outlives a restart")
    }
}
