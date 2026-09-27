import XCTest
@testable import Meepo

final class EventStoryTests: XCTestCase {
    private func event(_ id: Int64, _ name: String, _ summary: String?, at seconds: TimeInterval) -> HookEvent {
        HookEvent(id: id, sessionId: 1, name: name, summary: summary, isFailure: name.contains("Failure"),
                  createdAt: Date(timeIntervalSince1970: 1_000_000 + seconds))
    }

    func testAToolsStartAndEndAreOneLine() {
        let lines = EventStory.lines([
            event(1, "UserPromptSubmit", "давай импорт графика из Excel", at: 0),
            event(2, "PreToolUse", "Bash: cd /Users/me/taxinet && git status --short", at: 1),
            event(3, "PostToolUse", "Bash: cd /Users/me/taxinet && git status --short", at: 2),
            event(4, "PreToolUse", "Edit: /Users/me/taxinet/internal/reports.go", at: 3),
            event(5, "PreToolUse", "Bash: npm test", at: 4),
        ])
        XCTAssertEqual(lines.map(\.title), ["Ran npm test…", "Edited reports.go…", "Ran git status --short",
                                             "You asked: “давай импорт графика из Excel”"], "newest first; the finished call once")
        XCTAssertEqual(lines.map(\.isRunning), [true, true, false, false])
        XCTAssertEqual(lines[1].file, "/Users/me/taxinet/internal/reports.go")
        XCTAssertEqual(lines[2].detail, "Bash: cd /Users/me/taxinet && git status --short", "the raw text stays a click away")
    }

    func testACallWithoutAnEndStopsRunningWhenTheTurnEnds() {
        let lines = EventStory.lines([
            event(1, "PreToolUse", "Bash: npm test", at: 0),
            event(2, "Stop", "Tests pass.", at: 5),
        ])
        XCTAssertEqual(lines.last?.title, "Ran npm test")
        XCTAssertEqual(lines.last?.isRunning, false)
    }

    func testWhatNeedsYouAndWhatFailedStandOut() {
        let permission = EventStory.line(for: event(1, "PermissionRequest", "Bash: git push", at: 0))!
        XCTAssertTrue(permission.needsYou)
        XCTAssertEqual(permission.title, "Asked your permission: “Bash: git push”")
        let failed = EventStory.line(for: event(2, "PostToolUseFailure", "Bash: go test ./...", at: 0))!
        XCTAssertTrue(failed.isFailure)
        XCTAssertEqual(failed.title, "Failed: ran go test ./...")
    }

    func testShellCommandsLoseTheirCdPrefix() {
        XCTAssertEqual(EventStory.shortCommand("cd /a && cd b && go test ./..."), "go test ./...")
        XCTAssertEqual(EventStory.shortCommand("cd /a && git add . && git commit -m x"), "git add . …")
        XCTAssertEqual(EventStory.shortCommand("cd /a"), "cd /a", "a lone cd is what it did")
    }

    func testAQuestionReadsAsAQuestion() {
        let asked = EventStory.line(for: event(1, "PreToolUse", "Which approach: sliding refresh or 24 h?", at: 0))!
        XCTAssertEqual(asked.title, "Asked you: “Which approach: sliding refresh or 24 h?”")
        XCTAssertTrue(asked.needsYou)
    }

    /// The next request ends the one before it: that one has no reply of its own (Esc, or a message sent while
    /// Claude worked — the hook can't tell which), and it doesn't keep counting.
    func testARequestTheNextOneCutOffEndsWhereTheNextBegins() {
        let runs = Runs.from([
            event(1, "UserPromptSubmit", "import the schedule", at: 0),
            event(2, "UserPromptSubmit", "no, stop — do it differently", at: 120),
            event(3, "Stop", "Done.", at: 300),
        ])
        XCTAssertEqual(runs.map(\.outcome), [.noReply, .done])
        XCTAssertEqual(runs[0].worked(now: Date(timeIntervalSince1970: 9_999_999)), 120, "it doesn't keep counting")
    }

    /// Today's header counts pushes and requests, not prompts: "Today: 1 sent · 3 requests · Claude worked 10m 0s".
    @MainActor func testTheDayInOneLine() {
        let start = Date(timeIntervalSince1970: 2_000_000)
        let runs = [
            Run(sessionId: 1, startedAt: start, endedAt: start + 480, request: "a", files: ["x"], reply: "Done."),
            Run(sessionId: 1, startedAt: start + 600, endedAt: start + 660, request: "b", files: [], reply: "Commit it?"),
            Run(sessionId: 2, startedAt: start + 700, endedAt: nil, request: "c", files: [], reply: nil),
        ]
        XCTAssertEqual(runs.map(\.outcome), [.done, .askedYou, .working])
        let send = Work.Send(at: start + 650, from: "a", to: "b", after: nil, commits: [], files: 1)
        let rows = [TodayList.Row(unit: Work.Unit(kind: .sent(send), runs: Array(runs.prefix(2)), id: send.id, key: send.id, date: send.at),
                                  repo: nil, folder: "/f"),
                    TodayList.Row(unit: Work.Unit(kind: .now, runs: [runs[2]], id: "now", key: "now", date: start + 700), repo: nil, folder: "/f")]
        XCTAssertEqual(TodayList.header(rows, since: start, now: start + 760), "Today: 1 sent · 3 requests · Claude worked 10m 0s")
        XCTAssertEqual(TodayList.header([], since: start, now: start), "Nothing sent or asked yet today.")
    }
}
