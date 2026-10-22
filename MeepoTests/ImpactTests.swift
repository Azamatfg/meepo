import GRDB
import XCTest
@testable import Meepo

final class ImpactTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }
    private func iso(_ minutes: Double) -> String { Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(at(minutes)) }

    private func ended(_ minute: Double, session: String = "s") -> String {
        #"{"type":"assistant","sessionId":"\#(session)","timestamp":"\#(iso(minute))","message":{"stop_reason":"end_turn","content":[]}}"#
    }

    private func typed(_ minute: Double, session: String = "s", origin: String? = "human", text: String = "next") -> String {
        let origin = origin.map { #","origin":{"kind":"\#($0)"}"# } ?? ""
        return #"{"type":"user","sessionId":"\#(session)","cwd":"/work/app","timestamp":"\#(iso(minute))"\#(origin),"message":{"role":"user","content":"\#(text)"}}"#
    }

    /// A pause runs from a finished turn to the next thing you typed in that session: not a tool result, not a
    /// background task's notice; a prompt typed mid-turn isn't one; long ones are capped.
    func testPausesRunFromAFinishedTurnToWhatYouTypedNext() {
        let lines = [
            ended(0),
            #"{"type":"user","sessionId":"s","timestamp":"\#(iso(1))","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#,
            typed(1.5, origin: "task-notification", text: "<task-notification>done"),
            typed(2),                                   // 2 min after the turn ended
            typed(3),                                   // no turn ended since: not a pause
            ended(4, session: "t"), typed(5, session: "s"),
            ended(10), typed(100),                      // 90 min away: capped
            ended(200), typed(201, origin: nil, text: "<local-command-stdout>x"),
            typed(203, origin: nil, text: "plain, older claude"),
            #"{"type":"assistant","isSidechain":true,"sessionId":"s","timestamp":"\#(iso(300))","message":{"stop_reason":"end_turn"}}"#,
            typed(301),
        ]
        let pauses = Impact.pauses(transcript: Data(lines.joined(separator: "\n").utf8))
        XCTAssertEqual(pauses.map(\.seconds), [120, Impact.maxPause, 180])
        XCTAssertEqual(pauses.first?.cwd, "/work/app")
    }

    /// A repo and its worktree are one repo: its commits and CI aren't counted twice.
    func testAWorktreeIsItsRepo() throws {
        let repo = try makeTempRepo()
        try git(["commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        let worktree = repo.deletingLastPathComponent().appending(path: "wt-\(UUID().uuidString)")
        try git(["worktree", "add", "-q", worktree.path], in: repo)
        XCTAssertEqual(Impact.repos(of: [repo.path, AppStore.realPath(worktree.path)]), [repo.path])
    }

    /// A session opened through a link to the project (~/Projects/taxi) waits in the project too; old transcripts
    /// aren't read.
    func testPausesThroughALinkCountForTheRealFolder() throws {
        let tmp = URL(filePath: AppStore.realPath(FileManager.default.temporaryDirectory.appending(path: "pauses-\(UUID().uuidString)").path))
        defer { try? FileManager.default.removeItem(at: tmp) }
        let real = tmp.appending(path: "app"), link = tmp.appending(path: "link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let root = tmp.appending(path: "projects/-link")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lines = [ended(0), typed(2).replacingOccurrences(of: "/work/app", with: link.path)].joined(separator: "\n")
        let transcript = root.appending(path: "s.jsonl")
        try Data(lines.utf8).write(to: transcript)

        XCTAssertEqual(Impact.pauses(in: [real.path], root: tmp.appending(path: "projects")).map(\.seconds), [120])
        try FileManager.default.setAttributes([.modificationDate: at(-60 * 24 * 200)], ofItemAtPath: transcript.path)
        XCTAssertEqual(Impact.pauses(in: [real.path], since: at(-60 * 24 * 7), root: tmp.appending(path: "projects")).count, 0)
    }

    /// Rework = a fix or revert touching a file one of the commits changed within 48 hours before.
    func testReworkIsAFixOfAFileChangedInTheFortyEightHoursBefore() {
        let hour = { (h: Double) in self.start.addingTimeInterval(h * 3600) }
        let commits = [
            Impact.Commit(date: hour(0), subject: "feat: login", files: ["a.swift", "b.swift"]),
            Impact.Commit(date: hour(10), subject: "fix(auth): token", files: ["a.swift"]),
            Impact.Commit(date: hour(11), subject: "fix: unrelated", files: ["c.swift"]),
            Impact.Commit(date: hour(12), subject: "feat: more login", files: ["b.swift"]),
            Impact.Commit(date: hour(13), subject: "Revert \"feat: more login\"", files: ["b.swift"]),
            Impact.Commit(date: hour(100), subject: "fix: late", files: ["c.swift"]),
        ]
        XCTAssertEqual(Impact.reworked(commits.shuffled()).map(\.subject), ["fix(auth): token", "Revert \"feat: more login\""])
    }

    /// Before meepo: BEFORE. Before the list began: MEEPO. After: by the session, and a week goes to where most of
    /// its hours went.
    func testAWeekGoesToWhereMostOfItsHoursWent() {
        let day = 86400.0
        let attribution = Impact.Attribution(installed: at(0) + 7 * day, listedSince: at(0) + 14 * day, launched: ["m"])
        XCTAssertEqual(attribution.mode(session: "m", at: at(0)), .before)
        XCTAssertEqual(attribution.mode(session: "t", at: at(0) + 8 * day), .meepo, "no list yet: meepo was in use")
        XCTAssertEqual(attribution.mode(session: "t", at: at(0) + 15 * day), .terminal)
        XCTAssertEqual(attribution.mode(session: "m", at: at(0) + 15 * day), .meepo)

        let week3 = at(0) + 21 * day
        let entry = { (session: String, hour: Double) in
            Noticing.Entry(display: "x", date: week3.addingTimeInterval(hour * 3600), session: session, project: "/work/app")
        }
        let entries = [entry("t", 0), entry("t", 0.5), entry("t", 1), entry("m", 2)] // terminal 2 hours, meepo 1
        let ci = [true, false, false].enumerated().map { index, failed in
            CIRun(databaseId: Int64(index), workflowName: "ci", headBranch: "main", headSha: "", status: "completed",
                  conclusion: failed ? "failure" : "success", createdAt: week3, attempt: 1, url: "")
        } + [CIRun(databaseId: 9, workflowName: "ci", headBranch: "main", headSha: "", status: "completed",
                   conclusion: "cancelled", createdAt: week3, attempt: 1, url: "")]
        let weeks = Impact.weeks(now: week3 + 6 * day, count: 2, entries: entries,
                                 commits: [Impact.Commit(date: week3, subject: "feat: x", files: [])], ci: ci,
                                 pauses: [Impact.Pause(session: "t", cwd: "/work/app", date: week3, seconds: 600)],
                                 attribution: attribution, calendar: calendar)
        XCTAssertEqual(weeks.count, 1)
        XCTAssertEqual(weeks[0].mode, .terminal)
        XCTAssertEqual(weeks[0].totals.hours, 3)
        XCTAssertEqual(weeks[0].totals.shippedPerHour ?? 0, 1.0 / 3, accuracy: 0.001)
        XCTAssertEqual(weeks[0].totals.ciFailedShare ?? 0, 1.0 / 3, accuracy: 0.001, "a cancelled run isn't a result")
        XCTAssertEqual(weeks[0].totals.waitingMinutesPerDay, 10)
    }

    /// Waiting is the time at least one session waited for you: sessions waiting side by side count once.
    func testSessionsWaitingAtTheSameTimeCountOnce() {
        let day = 86400.0
        let attribution = Impact.Attribution(installed: at(0), listedSince: nil, launched: [])
        let pause = { (session: String, endMinute: Double, minutes: Double) in
            Impact.Pause(session: session, cwd: "/work/app", date: self.at(endMinute), seconds: minutes * 60)
        }
        // a: 0–10, b: 5–15 (overlap 5) → 15; c: 30–40 apart → 10. Summed would be 30.
        let weeks = Impact.weeks(now: at(0) + day, count: 1, entries: [], commits: [], ci: [],
                                 pauses: [pause("a", 10, 10), pause("b", 15, 10), pause("c", 40, 10)],
                                 attribution: attribution, calendar: calendar)
        XCTAssertEqual(weeks.first?.totals.waitingMinutesPerDay, 25)
    }

    func testTheListKeepsEachSessionOnce() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "launched-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        Impact.remember(["a", "b"], file: file)
        Impact.remember(["b", "c"], file: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "a\nb\nc\n")
    }

    /// The usage scan lists meepo's own sessions — a terminal session in the same folder stays off the list.
    func testTheScanListsOnlyMeeposSessions() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        try db.write { db in
            try db.execute(sql: "INSERT INTO project (id, name, path) VALUES (1, 'app', '/work/app')")
            try db.execute(sql: "INSERT INTO session (projectId, claudeSessionId, status, createdAt, lastActiveAt) VALUES (1, 'mine', 'idle', ?, ?)",
                           arguments: [start, start])
        }
        let tmp = FileManager.default.temporaryDirectory.appending(path: "impact-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp.appending(path: "-work-app"), withIntermediateDirectories: true)
        let line = { (session: String) in
            #"{"type":"assistant","sessionId":"\#(session)","cwd":"/work/app","timestamp":"2026-10-20T10:00:00Z","message":{"id":"m-\#(session)","model":"m","usage":{"input_tokens":1,"output_tokens":1}}}"#
        }
        for session in ["mine", "terminal"] {
            try Data((line(session) + "\n").utf8).write(to: tmp.appending(path: "-work-app/\(session).jsonl"))
        }
        let launched = tmp.appending(path: "launched")
        try UsageScanner.scan(root: tmp, into: db, launched: launched)
        XCTAssertEqual(try String(contentsOf: launched, encoding: .utf8), "mine\n")
    }

    func testGitLogBecomesCommitsWithTheirFiles() {
        let log = "\u{1e}1790000000\u{1f}fix: a: b\n\na.swift\nb/c.swift\n\u{1e}1789990000\u{1f}feat: x\n"
        XCTAssertEqual(Impact.parseLog(log), [
            Impact.Commit(date: Date(timeIntervalSince1970: 1_790_000_000), subject: "fix: a: b", files: ["a.swift", "b/c.swift"]),
            Impact.Commit(date: Date(timeIntervalSince1970: 1_789_990_000), subject: "feat: x", files: []),
        ])
    }
}
