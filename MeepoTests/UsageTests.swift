import GRDB
import XCTest
@testable import Meepo

/// JSONL lines in the real Claude Code 2.1.280 shape (trimmed): one response = several lines sharing message.id.
private func assistant(_ messageId: String, session: String, cwd: String = "/p/app", at time: String = "2026-09-23T10:00:00.000Z",
                       input: Int = 2, output: Int = 100, write: Int = 300, read: Int = 50_000, sidechain: Bool = false,
                       model: String = "claude-opus-5-5") -> String {
    #"{"type":"assistant","sessionId":"\#(session)","cwd":"\#(cwd)","timestamp":"\#(time)","isSidechain":\#(sidechain),"requestId":"req_\#(messageId)","message":{"id":"\#(messageId)","model":"\#(model)","role":"assistant","content":[],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":\#(write),"cache_read_input_tokens":\#(read),"cache_creation":{"ephemeral_1h_input_tokens":\#(write)},"iterations":[],"speed":"standard"}}}"#
}

private let noise = [
    #"{"type":"user","sessionId":"s","message":{"role":"user","content":"hi"}}"#,
    #"{"type":"cost-state","sessionId":"s","modelUsage":{"claude-opus-5-5":{"inputTokens":999999}}}"#,
    #"{"type":"file-history-snapshot","snapshot":{}}"#,
]

final class UsageScannerTests: XCTestCase {
    private var root: URL!
    private var db: DatabaseQueue!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "projects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "-p-app"), withIntermediateDirectories: true)
        db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
    }

    private func append(_ lines: [String], to name: String, newline: Bool = true) throws {
        let url = root.appending(path: "-p-app/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n") + (newline ? "\n" : "")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try handle.close()
        } else {
            try Data(text.utf8).write(to: url)
        }
    }

    private func total() throws -> Int {
        try db.read { try Int.fetchOne($0, sql: "SELECT SUM(inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens) FROM usageRecord") } ?? 0
    }

    func testSplitResponseLinesCountOnce() throws {
        // Text block and tool_use block of the same response, as Claude Code writes them.
        try append([assistant("m1", session: "s"), assistant("m1", session: "s")] + noise, to: "s.jsonl")
        try UsageScanner.scan(root: root, into: db)
        XCTAssertEqual(try total(), 2 + 100 + 300 + 50_000)
    }

    /// Real data (2026-09-23): lines of one response carry growing usage, e.g. totals 11571, 11571, 11726.
    /// Keeping the first line undercounted today's total by ~96K tokens.
    func testStreamedResponseKeepsFinalUsageEvenAcrossScans() throws {
        try append([assistant("m1", session: "s", output: 10), assistant("m1", session: "s", output: 10)], to: "s.jsonl")
        try UsageScanner.scan(root: root, into: db)
        try append([assistant("m1", session: "s", output: 165)], to: "s.jsonl") // final line lands in the next scan
        try UsageScanner.scan(root: root, into: db)
        XCTAssertEqual(try total(), 2 + 165 + 300 + 50_000)
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM usageRecord") }, 1)
    }

    func testCostStateIsNotCounted() throws {
        try append(noise, to: "s.jsonl")
        try UsageScanner.scan(root: root, into: db)
        XCTAssertEqual(try total(), 0)
    }

    func testLineBeingWrittenWaitsForNextScan() throws {
        let line = assistant("m1", session: "s")
        try append([String(line.prefix(40))], to: "s.jsonl", newline: false)
        try UsageScanner.scan(root: root, into: db)
        XCTAssertEqual(try total(), 0)
        try append([String(line.dropFirst(40))], to: "s.jsonl")
        try UsageScanner.scan(root: root, into: db)
        XCTAssertEqual(try total(), 50_402)
    }

    func testBrokenLineIsSkippedNotFatal() throws {
        try append([#"{"type":"assistant","usage": broken"#, assistant("m2", session: "s")], to: "s.jsonl")
        try UsageScanner.scan(root: root, into: db)
        XCTAssertEqual(try total(), 50_402)
    }

    /// SPEC module 3 "done when": after three session restarts in a day, the day total equals the sum over JSONL.
    func testThreeRestartsDayTotalMatchesJSONL() throws {
        // Run 1, then Meepo/claude restarts; --resume appends to the same file; Meepo rescans each time.
        try append([assistant("a1", session: "s1", output: 40), assistant("a1", session: "s1", output: 90), assistant("a2", session: "s1")], to: "s1.jsonl")
        try UsageScanner.scan(root: root, into: db)
        try append([assistant("a3", session: "s1")], to: "s1.jsonl")                 // restart 1: resume
        try UsageScanner.scan(root: root, into: db)
        try UsageScanner.scan(root: root, into: db)                                   // restart 2: nothing new
        try append([assistant("b1", session: "s2"), assistant("b1", session: "s2")], to: "s2.jsonl") // restart 3: /clear → new file
        try append([assistant("c1", session: "s2", sidechain: true)], to: "s2/subagents/agent-x.jsonl")
        try UsageScanner.scan(root: root, into: db)

        // Independent expectation straight from the files: unique message ids × their usage.
        var expected: [String: Int] = [:]
        for file in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.compactMap({ $0 as? URL })
        where file.pathExtension == "jsonl" {
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
                guard let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let message = json["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] else { continue }
                let n = { (key: String) in (usage[key] as! NSNumber).intValue }
                // Overwrite: the last line of a response carries its final usage.
                expected[message["id"] as! String] = n("input_tokens") + n("output_tokens")
                    + n("cache_creation_input_tokens") + n("cache_read_input_tokens")
            }
        }
        XCTAssertEqual(expected.count, 5)
        XCTAssertEqual(try total(), expected.values.reduce(0, +))
    }

    func testRewrittenFileIsRescannedWithoutDoubleCounting() throws {
        try append([assistant("m1", session: "s"), assistant("m2", session: "s")], to: "s.jsonl")
        try UsageScanner.scan(root: root, into: db)
        try Data((assistant("m1", session: "s") + "\n").utf8).write(to: root.appending(path: "-p-app/s.jsonl")) // shorter now
        try UsageScanner.scan(root: root, into: db)
        XCTAssertEqual(try total(), 2 * 50_402)
    }

    func testTokenFormat() {
        XCTAssertEqual(TokenFormat.short(812), "812")
        XCTAssertEqual(TokenFormat.short(3_450), "3.5K")
        XCTAssertEqual(TokenFormat.short(345_000), "345K")
        XCTAssertEqual(TokenFormat.short(1_234_567), "1.23M")
        XCTAssertEqual(TokenFormat.short(54_000_000), "54.0M")
    }
}

@MainActor
final class SessionUsageTests: XCTestCase {
    func testContextComesFromLatestMainResponseAndTodayIncludesSubagents() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "su-\(UUID().uuidString)")
        let root = tmp.appending(path: "projects")
        let store = AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "s.json"), meepoHome: tmp),
                             usageRoot: root, defaults: UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!)
        let repo = try makeTempRepo()
        try store.addProject(at: repo)
        try store.createSession(projectId: store.projects[0].id!, model: nil, prompt: nil)
        let session = store.sessions[0]
        let now = ISO8601DateFormatter().string(from: .now)
        let earlier = ISO8601DateFormatter().string(from: .now.addingTimeInterval(-60))
        let dir = root.appending(path: "-repo")
        try FileManager.default.createDirectory(at: dir.appending(path: "\(session.claudeSessionId)/subagents"), withIntermediateDirectories: true)
        let fractional = { (s: String) in s } // plain ISO 8601 without fractions must parse too
        try Data((assistant("m1", session: session.claudeSessionId, cwd: repo.path, at: fractional(earlier), read: 10_000) + "\n"
                  + assistant("m2", session: session.claudeSessionId, cwd: repo.path, at: fractional(now), input: 0, output: 0, write: 0, read: 100_000) + "\n").utf8)
            .write(to: dir.appending(path: "\(session.claudeSessionId).jsonl"))
        try Data((assistant("x1", session: session.claudeSessionId, cwd: repo.path, at: fractional(now), read: 190_000, sidechain: true) + "\n").utf8)
            .write(to: dir.appending(path: "\(session.claudeSessionId)/subagents/agent-1.jsonl"))

        await store.refreshUsage()

        let usage = try XCTUnwrap(store.sessionUsage[session.id!])
        XCTAssertEqual(usage.contextTokens, 100_000)                 // latest main response, not the subagent's 190K
        XCTAssertEqual(store.contextFraction(for: session.id!), 0.1) // of Opus 5.5's 1M window
        XCTAssertEqual(usage.tokensToday, 10_402 + 100_000 + 190_402)
        let stats = store.usageStats(since: Calendar.current.startOfDay(for: .now))
        XCTAssertEqual(stats.byProject.map(\.name), [store.projects[0].name])
        XCTAssertEqual(stats.total.total, usage.tokensToday)
    }
}

final class HookBlockTests: XCTestCase {
    /// The tool_result Claude Code 2.1.281 wrote when a PreToolUse hook exited 2 (captured live).
    func testBlockedToolCallIsReadFromTheTranscript() throws {
        let line = #"{"type":"user","sessionId":"s-1","timestamp":"2026-09-24T06:10:00.123Z","message":{"role":"user","content":[{"type":"tool_result","content":"PreToolUse:Bash hook error: [/Users/me/p/.claude/hooks/pre-bash-safety.sh]: Blocked: rm is not allowed\n","is_error":true,"tool_use_id":"toolu_1"}]}}"#
        let ok = #"{"type":"user","sessionId":"s-1","timestamp":"2026-09-24T06:11:00Z","message":{"role":"user","content":[{"type":"tool_result","content":"PreToolUse:Bash is in the output of a grep","is_error":false,"tool_use_id":"toolu_2"}]}}"#
        let blocks = UsageScanner.parseBlocks(Data((line + "\n" + ok + "\n").utf8))
        XCTAssertEqual(blocks.count, 1)                                   // a successful result mentioning it is not a block
        XCTAssertEqual(blocks[0].claudeSessionId, "s-1")
        XCTAssertEqual(blocks[0].summary, "Bash blocked by pre-bash-safety.sh: Blocked: rm is not allowed")
    }
    @MainActor
    func testBlockLandsInItsSessionsFeedOnceAndOthersAreSkipped() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "hb-\(UUID().uuidString)")
        let root = tmp.appending(path: "projects")
        let store = AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "s.json"), meepoHome: tmp),
                             usageRoot: root, defaults: UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!)
        try store.addProject(at: try makeTempRepo())
        try store.createSession(projectId: store.projects[0].id!, model: nil, prompt: nil)
        let session = store.sessions[0]
        func blocked(_ sessionId: String) -> String {
            #"{"type":"user","sessionId":"\#(sessionId)","timestamp":"2026-09-24T06:10:00.123Z","message":{"content":[{"type":"tool_result","content":"PreToolUse:Bash hook error: [/h/protect-env.sh]: .env is protected","is_error":true}]}}"#
        }
        let dir = root.appending(path: "-repo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data((blocked(session.claudeSessionId) + "\n" + blocked("not-a-meepo-session") + "\n").utf8)
            .write(to: dir.appending(path: "\(session.claudeSessionId).jsonl"))

        await store.refreshUsage()
        try await db.write { try $0.execute(sql: "DELETE FROM scanState") }                      // a rewritten file is scanned from the start
        await store.refreshUsage()

        let events = try await db.read { try HookEvent.filter(Column("name") == "HookBlocked").fetchAll($0) }
        XCTAssertEqual(events.map(\.summary), ["Bash blocked by protect-env.sh: .env is protected"])
        XCTAssertEqual(events.first?.sessionId, session.id)
        XCTAssertEqual(events.first?.isFailure, true)
    }
}
