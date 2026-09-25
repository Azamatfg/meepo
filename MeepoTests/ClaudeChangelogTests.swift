import GRDB
import XCTest
@testable import Meepo

private let changelog = """
# Changelog

## 2.1.283

- Added `statusLine` padding option
- Fixed a crash in the diff view

## 2.1.282

- Fixed hooks timing out on slow disks
- Improved startup time

## 2.1.281

- Old news
"""

final class ClaudeChangelogTests: XCTestCase {
    func testOnlyVersionsNewerThanTheLastSeen() {
        let releases = ClaudeChangelog.releases(in: changelog, after: "2.1.281", upTo: "2.1.283")
        XCTAssertEqual(releases.map(\.version), ["2.1.283", "2.1.282"])
        XCTAssertEqual(releases[1].items, ["Fixed hooks timing out on slow disks", "Improved startup time"])
    }

    func testLinesThatTouchTheSetupComeFirst() {
        let items = ClaudeChangelog.releases(in: changelog, after: "2.1.281", upTo: "2.1.283").flatMap(\.items)
        let sorted = ClaudeChangelog.relevantFirst(items, keywords: ClaudeChangelog.keywords(settings: [:]))
        XCTAssertEqual(sorted.relevant, ["Added `statusLine` padding option", "Fixed hooks timing out on slow disks"])
        XCTAssertEqual(sorted.other.count, 2)
    }

    func testSettingsAddTheirOwnWords() {
        XCTAssertTrue(ClaudeChangelog.keywords(settings: ["mcpServers": [:]]).contains("mcp"))
        XCTAssertFalse(ClaudeChangelog.keywords(settings: [:]).contains("mcp"), "no MCP servers, no MCP news")
    }

    func testCLIVersion() {
        XCTAssertEqual(ClaudeChangelog.version(fromCLI: "2.1.282 (Claude Code)"), "2.1.282")
        XCTAssertNil(ClaudeChangelog.version(fromCLI: "command not found"))
    }
}

@MainActor
final class ClaudeNewsStoreTests: XCTestCase {
    func testFirstRunIsTheBaselineThenNewsUntilAcknowledged() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "cn-\(UUID().uuidString)")
        let store = AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "s.json"), meepoHome: tmp),
                             usageRoot: tmp, defaults: UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!)
        store.noteClaudeVersion("2.1.281", changelog: changelog)
        XCTAssertTrue(store.claudeNews.isEmpty, "the first version Meepo sees is just the baseline")
        store.noteClaudeVersion("2.1.283", changelog: changelog)
        XCTAssertEqual(store.claudeNews.map(\.version), ["2.1.283", "2.1.282"])
        XCTAssertEqual(store.claudeNewsSince, "2.1.281")
        store.acknowledgeClaudeNews()
        store.noteClaudeVersion("2.1.283", changelog: changelog)
        XCTAssertTrue(store.claudeNews.isEmpty)
    }
}
