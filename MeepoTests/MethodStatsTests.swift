import XCTest
@testable import Meepo

final class MethodStatsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// Requests per push counts what you typed in this project (worktrees included), not slash commands or other
    /// folders; turns proven = turns that changed files and ended with the check passing.
    func testAWindowCountsTypedRequestsPerPushAndProvenTurns() {
        let at = { (minute: Double) in self.start.addingTimeInterval(minute * 60) }
        let entries = [
            Noticing.Entry(display: "add login", date: at(1), session: "s", project: "/work/app"),
            Noticing.Entry(display: "no, keep the button", date: at(2), session: "s", project: "/work/app/.claude/worktrees/x"),
            Noticing.Entry(display: "/ship", date: at(3), session: "s", project: "/work/app"),
            Noticing.Entry(display: "other repo", date: at(4), session: "t", project: "/work/app-old"),
        ]
        var id: Int64 = 0
        let event = { (name: String, summary: String, minute: Double) -> HookEvent in
            id += 1
            return HookEvent(id: id, sessionId: 1, name: name, summary: summary, isFailure: false, createdAt: at(minute))
        }
        let events = [event("UserPromptSubmit", "add login", 1), event("PostToolUse", "Edit: /work/app/a.ts", 1.5),
                      event("Verify", "passed: npm test", 1.8), event("Stop", "Done.", 2),
                      event("UserPromptSubmit", "no, keep the button", 2), event("PostToolUse", "Edit: /work/app/a.ts", 2.5),
                      event("Stop", "Kept.", 3)]
        let window = MethodStats.window(from: at(0), to: at(60), entries: entries, pushes: [at(5), at(120)],
                                        projects: ["/work/app"], events: events)
        XCTAssertEqual(window.requestsPerPush, 2)
        XCTAssertEqual(window.pushes, 1, "the push after the window isn't this window's")
        XCTAssertEqual(window.checkedShare, 0.5)
        XCTAssertNil(MethodStats.window(from: at(0), to: at(60), entries: entries, pushes: [], projects: ["/work/app"], events: [])
            .requestsPerPush, "no push: no ratio, not infinity")
    }
}
