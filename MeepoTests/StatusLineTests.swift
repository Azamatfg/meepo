import GRDB
import XCTest
@testable import Meepo

/// Claude Code 2.1.282's statusline input, trimmed to what Meepo reads.
private let sample = Data(#"""
{"session_id":"abc","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"effort":{"level":"xhigh"},
 "context_window":{"total_input_tokens":420000,"context_window_size":1000000,"used_percentage":42,"remaining_percentage":58},
 "rate_limits":{"five_hour":{"used_percentage":37.6,"resets_at":1790330400},"seven_day":{"used_percentage":81,"resets_at":1790700000}}}
"""#.utf8)

final class StatusLineParseTests: XCTestCase {
    func testReadsModelEffortContextAndLimits() throws {
        let status = try XCTUnwrap(StatusLine(json: sample))
        XCTAssertEqual(status.modelName, "Opus 5.5")
        XCTAssertEqual(status.effort, "xhigh")
        XCTAssertEqual(status.contextPercent, 42)
        XCTAssertEqual(status.contextWindow, 1_000_000)
        XCTAssertEqual(status.fiveHour?.percent, 37.6)
        XCTAssertEqual(status.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_790_330_400))
        XCTAssertEqual(status.sevenDay?.percent, 81)
    }

    func testAHookEventIsNotAStatusLine() {
        XCTAssertNil(StatusLine(json: Data(#"{"hook_event_name":"Stop","session_id":"abc","model":"x"}"#.utf8)))
        XCTAssertNil(StatusLine(json: Data("not json".utf8)))
    }

    func testMeepoSessionSettingsCarryTheStatusLine() throws {
        let args = ClaudeLauncher.sessionSettings(effort: nil, statusLine: #"f='/x y'; [ -x "$f" ] && exec "$f" statusline; exit 0"#)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(args[1].utf8)) as? [String: Any])
        let line = try XCTUnwrap(json["statusLine"] as? [String: Any])
        XCTAssertEqual(line["type"] as? String, "command")
        XCTAssertTrue((line["command"] as? String)?.hasSuffix("statusline; exit 0") == true, "quotes survive the JSON")
    }
}

@MainActor
final class StatusLineStoreTests: XCTestCase {
    func testClaudeCodesOwnNumbersWin() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "sl-\(UUID().uuidString)")
        let store = AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "s.json"), meepoHome: tmp),
                             usageRoot: tmp, defaults: UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!)
        try store.addProject(at: try makeTempRepo())
        try store.createSession(projectId: store.projects[0].id!, model: "opus", prompt: nil, effort: "high")
        let session = store.sessions[0]
        XCTAssertEqual(store.modelLine(of: session), "opus · high", "before Claude Code says anything")
        store.applyStatusLine(try XCTUnwrap(StatusLine(json: sample)), sessionId: session.id!)
        XCTAssertEqual(store.contextFraction(for: session.id!), 0.42)
        XCTAssertEqual(store.modelLine(of: session), "Opus 5.5 · xhigh", "what it really runs")
        XCTAssertEqual(store.usageLimits?.sevenDay?.percent, 81)
    }
}

/// The statusline branch of the real bridge script: Meepo gets the JSON, the user's own statusline still prints.
final class BridgeStatusLineTests: XCTestCase {
    func testTheUsersOwnStatusLineStillShows() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "slb-\(UUID().uuidString)")
        let installer = BridgeInstaller(settingsURL: dir.appending(path: "settings.json"), meepoHome: dir)
        try installer.writeScript()
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", installer.statusLineCommand]
        // No Meepo on this port: the POST fails quietly and the user's line comes out anyway.
        process.environment = ["MEEPO_SESSION_ID": "1", "MEEPO_PORT": "1", "HOME": dir.path,
                               "PATH": "/usr/bin:/bin", "MEEPO_USER_STATUSLINE": #"echo "mine: $(wc -c | tr -d ' ')""#]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data("12345".utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "mine: 5\n",
                       "the user's command gets the same JSON Claude Code sent")
    }
}
