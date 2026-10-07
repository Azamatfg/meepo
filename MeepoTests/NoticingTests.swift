import GRDB
import XCTest
@testable import Meepo

final class NoticingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func entry(_ display: String, _ minute: Int, session: String = "s1") -> Noticing.Entry {
        Noticing.Entry(display: display, date: start.addingTimeInterval(Double(minute) * 60), session: session)
    }

    func testChainsAreOrderedRunsInOneSession() {
        var entries: [Noticing.Entry] = []
        for i in 0..<5 {
            let s = "s\(i)"
            entries += [entry("/simplify", i * 100, session: s), entry("/simplify", i * 100 + 1, session: s),
                        entry("fix the test", i * 100 + 2, session: s), entry("/ship", i * 100 + 3, session: s),
                        entry("/sync", i * 100 + 4, session: s), entry("/exit", i * 100 + 5, session: s)]
        }
        let chains = Noticing.chains(entries, known: ["simplify", "ship", "sync"], since: start)
        XCTAssertEqual(chains.map(\.kind), [.chain(["simplify", "ship", "sync"])], "the pairs inside the triple aren't offered again; /exit isn't a skill")
        XCTAssertEqual(chains.first?.count, 5)
        XCTAssertTrue(Noticing.chains(Array(entries.prefix(24)), known: ["simplify", "ship", "sync"], since: start).isEmpty,
                      "four times isn't a habit yet")
    }

    func testChainsDontCrossSessions() {
        let entries = (0..<6).flatMap { i in [entry("/qa", i * 10, session: "a\(i)"), entry("/ship", i * 10 + 1, session: "b\(i)")] }
        XCTAssertTrue(Noticing.chains(entries, known: ["qa", "ship"], since: start).isEmpty)
    }

    func testRepeatedRequestsButNotPastesPathsOrShortReplies() {
        var entries: [Noticing.Entry] = []
        for i in 0..<5 {
            entries += [entry("Забери последние коммиты и проверь на конфликты.", i), entry("да", i),
                        entry("'/var/folders/yy/T/TemporaryItems/NSIRD_screencap", i), entry("[Pasted text #1 +3 lines]", i)]
        }
        let found = Noticing.repeatedPrompts(entries, since: start)
        XCTAssertEqual(found.map(\.kind), [.skill(phrase: "забери последние коммиты и проверь на конфликты")])
    }

    func testMeasuringBeforeAndAfter() {
        let release = start.addingTimeInterval(28 * 86_400)
        let before = (0..<28).map { entry("/usage", $0 * 1440) }            // daily for 4 weeks
        let after = (0..<2).map { entry("/usage", 28 * 1440 + $0 * 4000) }  // twice in the 2 weeks since
        let rate = Noticing.rate(of: "usage", in: before + after + [entry("/usage-report", 28 * 1440 + 10)],
                                 around: release, now: release.addingTimeInterval(14 * 86_400))
        XCTAssertEqual(rate.before, 7)
        XCTAssertEqual(rate.after, 1, "/usage-report isn't /usage")
        XCTAssertNil(Noticing.rate(of: "usage", in: before, around: release, now: release.addingTimeInterval(86_400)).after,
                     "a day says nothing yet")
    }
}

@MainActor
final class SuggestionStoreTests: XCTestCase {
    private var store: AppStore!
    private var home: URL!

    override func setUp() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        home = FileManager.default.temporaryDirectory.appending(path: "chain-\(UUID().uuidString)")
        store = AppStore(db: db, bridge: BridgeInstaller(settingsURL: home.appending(path: ".claude/settings.json"), meepoHome: home.appending(path: ".meepo")),
                         usageRoot: home, defaults: UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!)
        try store.addProject(at: try makeTempRepo())
    }

    private func storeWith(_ defaults: UserDefaults) throws -> AppStore {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "retire-\(UUID().uuidString)")
        return AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: ".claude/settings.json"), meepoHome: tmp),
                        usageRoot: tmp, defaults: defaults)
    }

    func testOldChainsComeBackAsRetiredButtons() throws {
        let defaults = UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!
        defaults.set(try JSONEncoder().encode([["simplify", "sync"]]), forKey: "chains")
        defaults.set(["simplify>sync": 2], forKey: "chainRuns")
        let applied = ["chain:simplify>sync": AppStore.SuggestionState(dismissedAt: nil, appliedAt: .now)]
        defaults.set(try JSONEncoder().encode(applied), forKey: "suggestionStates")
        let store = try storeWith(defaults)
        XCTAssertNil(store.suggestionStates["chain:simplify>sync"]?.appliedAt, "offered again, now as a skill button")
        XCTAssertEqual(store.suggestionStates["chain:simplify>sync"]?.retired, true)
        XCTAssertNil(defaults.object(forKey: "chains"))
        XCTAssertNil(defaults.object(forKey: "chainRuns"))
    }

    /// The tester's defaults: "chains" already gone, a run count of the 0.3 button left behind. That button was
    /// offered as if it were new ("You run /simplify → /sync"); it's the old button, switched off.
    func testLeftoverRunCountIsARetiredButton() throws {
        let defaults = UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!
        defaults.set(["simplify>sync": 1, "qa>ship": 3], forKey: "chainRuns")
        defaults.set(["qa-ship"], forKey: "skillButtons") // made again in 0.4 already
        let store = try storeWith(defaults)
        let old = Noticing.Suggestion(kind: .chain(["simplify", "sync"]), count: 0)
        XCTAssertTrue(store.isRetired(old))
        XCTAssertEqual(store.visibleSuggestions.map(\.id), ["chain:simplify>sync"],
                       "told even when history no longer counts it; the one already made again isn't")
        XCTAssertNil(defaults.object(forKey: "chainRuns"))

        store.dismissSuggestion(old)
        XCTAssertTrue(store.visibleSuggestions.isEmpty, "Not now: not told again")
        XCTAssertFalse(store.isRetired(old))
    }

    func testMakeItAgainIsAnOrdinaryButtonAfterwards() throws {
        let defaults = UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!
        defaults.set(["simplify>sync": 1], forKey: "chainRuns")
        let store = try storeWith(defaults)
        let old = try XCTUnwrap(store.visibleSuggestions.first)
        try store.makeButton(from: old)
        XCTAssertEqual(store.skillButtons, ["simplify-sync"])
        XCTAssertTrue(store.visibleSuggestions.isEmpty)
        store.removeButton("simplify-sync")
        XCTAssertFalse(store.isRetired(old), "removed later, it comes back as a habit, not as the 0.3 button")
    }

    /// Remove → Make a button: the skill is there with the same steps, so it's pinned again — it used to fail
    /// with "You already have a skill called …".
    func testRemovedButtonIsPinnedAgainWithoutWriting() throws {
        let suggestion = Noticing.Suggestion(kind: .chain(["qa", "ship"]), count: 6)
        try store.makeButton(from: suggestion)
        let file = home.appending(path: ".claude/skills/qa-ship/SKILL.md")
        let text = try String(contentsOf: file, encoding: .utf8)
        store.removeButton("qa-ship")
        XCTAssertNoThrow(try store.makeButton(from: suggestion))
        XCTAssertEqual(store.skillButtons, ["qa-ship"])
        XCTAssertNotNil(store.suggestionStates[suggestion.id]?.appliedAt)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text)
        XCTAssertEqual(ChangeLog.entries(backups: store.backupsDir).count, 1, "nothing written the second time")
    }

    func testSameNameOtherStepsLeavesTheSkillAlone() throws {
        try store.makeButton(named: "qa-ship", steps: [.command("qa"), .command("ship")])
        let file = home.appending(path: ".claude/skills/qa-ship/SKILL.md")
        let text = try String(contentsOf: file, encoding: .utf8)
        store.removeButton("qa-ship")
        XCTAssertThrowsError(try store.makeButton(named: "qa-ship", steps: [.command("verify")]))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text)
        XCTAssertTrue(store.skillButtons.isEmpty)
    }

    func testAButtonOfCommandsAnswersItsChain() throws {
        try store.makeButton(named: "tidy", steps: [.command("simplify"), .command("sync")])
        XCTAssertNotNil(store.suggestionStates["chain:simplify>sync"]?.appliedAt, "whatever the button is called")
        try store.makeButton(named: "tidy-and-test", steps: [.command("simplify"), .command("ship"), .prompt("run the tests")])
        XCTAssertNil(store.suggestionStates["chain:simplify>ship"], "words among the steps: not the chain meepo noticed")
    }

    func testNotNowComesBackWhenTheHabitDoubles() throws {
        let suggestion = Noticing.Suggestion(kind: .chain(["qa", "ship"]), count: 6)
        store.dismissSuggestion(suggestion)
        XCTAssertEqual(store.suggestionStates[suggestion.id]?.dismissedAt, 6)
        try store.makeButton(from: suggestion)
        XCTAssertNotNil(store.suggestionStates[suggestion.id]?.appliedAt)
        store.removeButton("qa-ship")
        XCTAssertNil(store.suggestionStates[suggestion.id]?.appliedAt, "removing the button makes it a suggestion again")
    }
}

final class MeasureTextTests: XCTestCase {
    func testWordsForEachStage() {
        XCTAssertEqual(AutomationsView.measureText("usage", nil), "You typed /usage …")
        XCTAssertEqual(AutomationsView.measureText("usage", (11, nil)), "You typed /usage 11× a week before — measuring, check back after a week.")
        XCTAssertEqual(AutomationsView.measureText("usage", (11, 3)), "You typed /usage 11× a week before, 3× a week since.")
    }
}

final class NeighborRepoTests: XCTestCase {
    private let home = "/Users/me"
    private let roots = ["/Users/me/Projects/ocpi", "/Users/me/Projects/tech-b", "/Users/me/Projects/alva-backend"]
    private func root(_ path: String) -> String? { roots.first { path == $0 || path.hasPrefix($0 + "/") } }

    /// Working there counts — cd, git -C, a file read or edited; a path only mentioned doesn't.
    func testOnlyWorkingInAFolderCounts() {
        XCTAssertEqual(Noticing.workedPaths("Bash: cd ~/Projects/ocpi/service && sed -n 95,107p x.go", home: home),
                       ["/Users/me/Projects/ocpi/service"])
        XCTAssertEqual(Noticing.workedPaths(#"Bash: git -C "/Users/me/Projects/tech-b" status"#, home: home), ["/Users/me/Projects/tech-b"])
        XCTAssertEqual(Noticing.workedPaths("Edit: /Users/me/Projects/ocpi/main.go", home: home), ["/Users/me/Projects/ocpi/main.go"])
        XCTAssertEqual(Noticing.workedPaths("Bash: sqlite3 db \"select … like '%Projects/ocpi%'\"", home: home), [])
        XCTAssertEqual(Noticing.workedPaths("Bash: ls ~/Projects/ocpi", home: home), [], "listing it isn't working in it")
    }

    func testRepoWorkedInOftenIsSuggestedOnceForItsProject() {
        let project = "/Users/me/Projects/alva-backend"
        let events = Array(repeating: (project: project, name: "alva-backend", summary: "Bash: cd ~/Projects/ocpi && go test ./..."), count: 5)
            + Array(repeating: (project: project, name: "alva-backend", summary: "Bash: cd ~/Projects/tech-b && make"), count: 4)
            + Array(repeating: (project: project, name: "alva-backend", summary: "Edit: /Users/me/Projects/alva-backend/app.py"), count: 9)
        let found = Noticing.neighborRepos(events, home: home, isKnown: { _ in false }, repoRoot: root)
        XCTAssertEqual(found, [Noticing.Suggestion(kind: .neighborRepo(repo: "/Users/me/Projects/ocpi", project: "alva-backend"), count: 5)],
                       "tech-b is under the threshold; the project's own repo never counts")
    }

    func testRepoMeepoAlreadyShowsIsNotSuggested() {
        let events = Array(repeating: (project: "/Users/me/Projects/alva-backend", name: "alva-backend", summary: "Bash: cd ~/Projects/ocpi && make"), count: 9)
        XCTAssertEqual(Noticing.neighborRepos(events, home: home, isKnown: { $0 == "/Users/me/Projects/ocpi" }, repoRoot: root), [])
    }
}
