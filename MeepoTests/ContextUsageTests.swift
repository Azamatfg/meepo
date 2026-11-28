import GRDB
import SwiftUI
import XCTest
@testable import Meepo

/// The session's context window by part, as the mod measures it after each turn (`$.session.usage({ breakdown })`).
@MainActor
final class ContextUsageTests: XCTestCase {
    private let body = Data("""
        {"hook_event_name":"ContextUsage","session_id":"c1","percent":41,"tokens":82000,"window":200000,"autoCompactAt":167000,
         "categories":[{"name":"System prompt","tokens":3100,"kind":"used"},{"name":"Messages","tokens":61000,"kind":"used"},
                       {"name":"MCP tools","tokens":9000,"kind":"deferred"},{"name":"Free space","tokens":100000,"kind":"free"}],
         "memoryFiles":[{"path":"/p/CLAUDE.md","type":"Project","tokens":2400},{"path":"/u/.claude/CLAUDE.md","type":"User","tokens":5200}],
         "skills":[{"name":"plan","tokens":40},{"name":"deliver","tokens":90}],
         "mcp":[{"server":"figma","tokens":7000},{"server":"gmail","tokens":2000}]}
        """.utf8)

    func testTheModsMeasurementReadsAsParts() throws {
        let usage = try XCTUnwrap(ContextUsage(json: body))
        XCTAssertEqual(usage.percent, 41)
        XCTAssertEqual(usage.used.map(\.name), ["Messages", "System prompt"], "what fills the window, heaviest first")
        XCTAssertEqual(usage.memoryFiles.first?.path, "/u/.claude/CLAUDE.md", "heaviest first")
        XCTAssertEqual(usage.skills.first?.name, "deliver")
        XCTAssertEqual(usage.mcp.map(\.server), ["figma", "gmail"])
        XCTAssertNil(ContextUsage(json: Data(#"{"hook_event_name":"Stop","session_id":"c1"}"#.utf8)), "a hook event isn't one")
    }

    func testInstructionsLoadedIsKeptPerSessionOncePerFile() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        let loaded = { (reason: String) in
            Data(#"{"hook_event_name":"InstructionsLoaded","session_id":"c1","file_path":"/p/.claude/rules/api.md","memory_type":"Project","load_reason":"\#(reason)"}"#.utf8)
        }
        XCTAssertTrue(store.applyContextReport(loaded("path_glob_match"), sessionId: 7))
        XCTAssertTrue(store.applyContextReport(loaded("compact"), sessionId: 7))
        XCTAssertEqual(store.loadedInstructions[7]?.map(\.reason), ["compact"], "one row per file, the latest reason")
        XCTAssertTrue(store.applyContextReport(body, sessionId: 7))
        XCTAssertEqual(store.contextUsage[7]?.percent, 41)
        XCTAssertFalse(store.applyContextReport(Data(#"{"hook_event_name":"Stop","session_id":"c1"}"#.utf8), sessionId: 7))
    }

    /// The panel as a picture, for looking at by eye (MEEPO_SNAPSHOT_DIR, as ShellSnapshotTests).
    func testPanelPicture() async throws {
        let path = ProcessInfo.processInfo.environment["MEEPO_SNAPSHOT_DIR"]
        try XCTSkipIf(path == nil, "pictures only on request")
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        try store.addProject(at: try makeTempRepo())
        try store.createSession(projectId: store.projects[0].id!, model: nil, prompt: nil)
        let id = try XCTUnwrap(store.selectedSessionId)
        _ = store.applyContextReport(body, sessionId: id)
        _ = store.applyContextReport(Data(#"{"hook_event_name":"InstructionsLoaded","session_id":"c1","file_path":"/p/.claude/rules/api.md","memory_type":"Project","load_reason":"path_glob_match"}"#.utf8), sessionId: id)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 320, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ContextPanel().padding(12).frame(width: 320, height: 620, alignment: .top)
            .background(Tokens.surface).environment(store))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .seconds(1))
        let view = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path!).appending(path: "context-panel.png"))
    }
}
