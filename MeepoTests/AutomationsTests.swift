import GRDB
import XCTest
@testable import Meepo

final class AutomationsUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func line(_ display: String, daysAgo: Double) -> Substring {
        let ms = Int((now.timeIntervalSince1970 - daysAgo * 86_400) * 1000)
        return Substring(#"{"display":"\#(display)","timestamp":\#(ms),"project":"/p","sessionId":"s"}"#)
    }

    func testCountsSlashCommandsByWeek() throws {
        let usage = Automations.usage(historyLines: [
            line("/qa", daysAgo: 1), line("/qa now please", daysAgo: 2), line("/qa", daysAgo: 8),
            line("/ship", daysAgo: 100), line("fix the login", daysAgo: 1), line("/", daysAgo: 1),
        ], now: now)
        let qa = try XCTUnwrap(usage["qa"])
        XCTAssertEqual(qa.weekly.suffix(2), [1, 2], "this week last")
        XCTAssertEqual(qa.total, 3)
        XCTAssertEqual(usage["ship"]?.total, 0, "older than 8 weeks isn't counted…")
        XCTAssertNotNil(usage["ship"]?.lastUsed, "…but still known as used")
        XCTAssertNil(usage["fix"], "plain prompts aren't commands")
    }

    func testFadingIsAMonthUnusedAndNeverBuiltIns() {
        func item(_ owner: Automations.Owner, lastUsed: Date?) -> Automations.Item {
            Automations.Item(name: "x", description: nil, file: nil, owner: owner, projects: [],
                             usage: Automations.Usage(weekly: [], lastUsed: lastUsed), effort: nil, model: nil)
        }
        XCTAssertTrue(Automations.isFading(item(.personal, lastUsed: now.addingTimeInterval(-40 * 86_400)), now: now))
        XCTAssertFalse(Automations.isFading(item(.personal, lastUsed: now.addingTimeInterval(-3 * 86_400)), now: now))
        XCTAssertTrue(Automations.isFading(item(.team, lastUsed: nil), now: now))
        XCTAssertFalse(Automations.isFading(item(.builtIn, lastUsed: nil), now: now), "built-ins aren't the user's to fold")
    }

    func testFrontmatterEdits() {
        let text = "---\ndescription: ship it\n---\nbody"
        let withEffort = Automations.settingFrontmatter("effort", to: "high", in: text)
        XCTAssertEqual(Automations.frontmatterValue("effort", in: withEffort), "high")
        XCTAssertEqual(Automations.frontmatterValue("description", in: withEffort), "ship it")
        XCTAssertEqual(Automations.settingFrontmatter("effort", to: "max", in: withEffort), "---\ndescription: ship it\neffort: max\n---\nbody")
        XCTAssertEqual(Automations.settingFrontmatter("effort", to: nil, in: withEffort), text, "default removes the line")
        XCTAssertEqual(Automations.settingFrontmatter("model", to: "opus", in: "just body"), "---\nmodel: opus\n---\njust body")
        XCTAssertEqual(Automations.settingFrontmatter("model", to: nil, in: "just body"), "just body")
    }
}

@MainActor
final class AutomationsStoreTests: XCTestCase {
    func testTeamFilesAreTheTrackedOnesAndOverridesArePersonal() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "auto-\(UUID().uuidString)")
        let store = AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: ".claude/settings.json"), meepoHome: tmp),
                             usageRoot: tmp, defaults: UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!)
        let repo = try makeTempRepo()
        let commands = repo.appending(path: ".claude/commands")
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        try "---\ndescription: team ship\n---\n".write(to: commands.appending(path: "teamship.md"), atomically: true, encoding: .utf8)
        try git(["add", ".claude/commands/teamship.md"], in: repo)
        try git(["commit", "-q", "-m", "team command"], in: repo)
        try "mine".write(to: commands.appending(path: "mynotes.md"), atomically: true, encoding: .utf8)
        try store.addProject(at: repo)

        let items = await store.automations()
        XCTAssertEqual(items.first { $0.name == "teamship" }?.owner, .team)
        XCTAssertEqual(items.first { $0.name == "mynotes" }?.owner, .personal, "in the project but not in git: the user's own")
        XCTAssertEqual(items.first { $0.name == "verify" }?.owner, .builtIn)

        try store.setSkillOverride("teamship", to: "user-invocable-only")
        XCTAssertEqual(store.skillOverrides()["teamship"], "user-invocable-only")
        XCTAssertEqual(try String(contentsOf: commands.appending(path: "teamship.md"), encoding: .utf8), "---\ndescription: team ship\n---\n",
                       "the team's file is never edited")
        try store.setSkillOverride("teamship", to: "on")
        XCTAssertNil(store.skillOverrides()["teamship"])

        let mine = try XCTUnwrap(items.first { $0.name == "mynotes" })
        try store.setFrontmatter(mine, "effort", to: "high")
        XCTAssertEqual(try String(contentsOf: commands.appending(path: "mynotes.md"), encoding: .utf8), "---\neffort: high\n---\nmine")
        let team = try XCTUnwrap(items.first { $0.name == "teamship" })
        try store.setFrontmatter(team, "effort", to: "high")
        XCTAssertFalse(try String(contentsOf: commands.appending(path: "teamship.md"), encoding: .utf8).contains("effort"))
    }
}
