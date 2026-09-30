import GRDB
import XCTest
@testable import Meepo

@MainActor
final class UsageCountsTests: XCTestCase {
    private func database() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        return db
    }

    /// Per name and day; only counts, and gone on Forget.
    func testCountsAddUpPerDayAndForgetClearsThem() throws {
        let db = try database()
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        UsageCounts.add("panel.explorer", on: day, in: db)
        UsageCounts.add("panel.explorer", on: day, in: db)
        UsageCounts.add("panel.explorer", on: day.addingTimeInterval(86400), in: db)
        UsageCounts.add("stage.qa", on: day.addingTimeInterval(-30 * 86400), in: db)
        let (counts, first) = UsageCounts.totals(since: day.addingTimeInterval(-86400), in: db)
        XCTAssertEqual(counts, ["panel.explorer": 3], "stage.qa was counted before the window")
        XCTAssertEqual(first, UsageCounts.day(day.addingTimeInterval(-30 * 86400)))
        UsageCounts.forget(in: db)
        XCTAssertEqual(UsageCounts.totals(since: .distantPast, in: db).counts, [:])
    }

    /// Nothing is "unused" until counting has run for the whole quiet period — a fresh install asks nothing.
    func testUnusedOnlyAfterAFullQuietPeriod() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let candidates = ["panel.explorer", "panel.ci"]
        XCTAssertEqual(UsageCounts.unused(candidates, counts: [:], firstDay: UsageCounts.day(now.addingTimeInterval(-3 * 86400)), now: now), [])
        XCTAssertEqual(UsageCounts.unused(candidates, counts: [:], firstDay: nil, now: now), [])
        XCTAssertEqual(UsageCounts.unused(candidates, counts: ["panel.ci": 2],
                                          firstDay: UsageCounts.day(now.addingTimeInterval(-20 * 86400)), now: now), ["panel.explorer"])
    }

    /// The store: counting off records nothing; an unused panel becomes a suggestion, and Hide it takes it out.
    func testUnusedPanelIsSuggestedAndHidden() throws {
        let store = makeIsolatedStore(db: try database())
        store.applyPreset(.full) // explorer + changes left, events + ci bottom
        store.learnsUsage = false
        store.count("panel.explorer")
        XCTAssertEqual(store.usageSuggestions(now: .now.addingTimeInterval(15 * 86400)), [], "off: nothing counted, nothing asked")
        store.learnsUsage = true
        store.count("panel.changes")
        let later = Date.now.addingTimeInterval(15 * 86400) // counting started today, 15 days before "later"
        let ids = store.usageSuggestions(now: later).map(\.id)
        XCTAssertTrue(ids.contains("panel:explorer") && ids.contains("stage:qa"), "\(ids)")
        let explorer = try XCTUnwrap(store.usageSuggestions(now: later).first { $0.id == "panel:explorer" })
        store.hideUnused(explorer)
        XCTAssertNil(store.shell.zone(of: .explorer))
        XCTAssertFalse(store.usageSuggestions(now: later).map(\.id).contains("panel:explorer"), "hidden: not in the layout any more")
        store.forgetUsage()
        XCTAssertEqual(store.usageSuggestions(now: later), [], "forgotten: counting starts over")
    }

    /// MORE → Pin to the bar: a plain command (no steps) becomes a button once.
    func testPinnedCommandIsAButtonOnce() throws {
        let store = makeIsolatedStore(db: try database())
        store.pinCommand("starting-session")
        store.pinCommand("starting-session")
        XCTAssertEqual(store.skillButtons.filter { $0 == "starting-session" }.count, 1)
        XCTAssertTrue(Recipes.canRun([], with: []), "no steps: nothing that could be missing")
    }
}
