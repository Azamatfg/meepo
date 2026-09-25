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
final class ChainRunTests: XCTestCase {
    private var store: AppStore!
    private var session: Session { store.sessions[0] }

    override func setUp() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "chain-\(UUID().uuidString)")
        store = AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "s.json"), meepoHome: tmp),
                         usageRoot: tmp, defaults: UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!)
        try store.addProject(at: try makeTempRepo())
        try store.createSession(projectId: store.projects[0].id!, model: nil, prompt: nil)
    }

    private func stop(_ reply: String, background: Int = 0) {
        var payload = HookPayload(event: "Stop", claudeSessionId: session.claudeSessionId, lastAssistantMessage: reply)
        payload.backgroundTasks = background
        store.handleHookEvent(payload, sessionId: session.id!)
    }

    func testEachStepWaitsForTheRealEndAndQuestionsPause() {
        store.runChain(["simplify", "ship", "sync"], in: session.id!)
        XCTAssertEqual(store.runningChains[session.id!]?.next, 1)
        stop("Started the build.", background: 1)
        XCTAssertEqual(store.runningChains[session.id!]?.next, 1, "background work still running: not done")
        stop("Simplified three files.")
        XCTAssertEqual(store.runningChains[session.id!]?.next, 2)
        stop("Push to main now?")
        XCTAssertEqual(store.runningChains[session.id!]?.paused, true, "Claude asked: the user answers first")
        stop("Pushed.")
        XCTAssertEqual(store.runningChains[session.id!]?.next, 2, "paused stays paused")
        store.resumeChain(session.id!)
        XCTAssertEqual(store.runningChains[session.id!]?.next, 3)
        stop("Memory updated.")
        XCTAssertNil(store.runningChains[session.id!])
        XCTAssertEqual(store.chainRuns["simplify>ship>sync"], 1, "measured: ran to the end once")
    }

    func testNotNowComesBackWhenTheHabitDoubles() {
        let suggestion = Noticing.Suggestion(kind: .chain(["qa", "ship"]), count: 6)
        store.dismissSuggestion(suggestion)
        XCTAssertEqual(store.suggestionStates[suggestion.id]?.dismissedAt, 6)
        store.addChain(["qa", "ship"], from: suggestion)
        XCTAssertNotNil(store.suggestionStates[suggestion.id]?.appliedAt)
        store.removeChain(["qa", "ship"])
        XCTAssertNil(store.suggestionStates[suggestion.id]?.appliedAt, "removing the button makes it a suggestion again")
    }
}
