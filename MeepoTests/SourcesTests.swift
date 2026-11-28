import GRDB
import SwiftUI
import XCTest
@testable import Meepo

/// Sources (2026-11-28): what Claude reads in a project besides the conversation, when, at what cost; the memory.
final class SourcesTests: XCTestCase {
    private let home = "/Users/me"
    private let folder = "/Users/me/work/app"

    private func scan(_ files: [String: String], tracked: [String] = [], measured: [String: Int] = [:],
                      loaded: Set<String> = []) -> [Sources.Instruction] {
        Sources.instructions(folder: folder, home: home, tracked: tracked, measured: measured, loaded: loaded,
                             read: { files[$0] },
                             list: { dir in files.keys.filter { $0.hasPrefix(dir + "/") && $0.hasSuffix(".md") }.sorted() })
    }

    func testEachFileLoadsWhenItShould() {
        let files = [
            "\(home)/.claude/CLAUDE.md": "user rules",
            "/Users/me/work/CLAUDE.md": "parent",
            "\(folder)/CLAUDE.md": "project",
            "\(folder)/CLAUDE.local.md": "mine",
            "\(folder)/.claude/rules/api.md": "---\npaths:\n  - \"src/api/**\"\n  - lib/*.ts\n---\nUse zod.",
            "\(folder)/.claude/rules/style.md": "No paths here.",
            "\(folder)/ios/CLAUDE.md": "nested",
        ]
        let found = scan(files, tracked: ["CLAUDE.md", "ios/CLAUDE.md"])
        let by = Dictionary(uniqueKeysWithValues: found.map { ($0.path, $0) })
        XCTAssertEqual(by["\(home)/.claude/CLAUDE.md"]?.scope, "user")
        XCTAssertEqual(by["/Users/me/work/CLAUDE.md"]?.scope, "parent")
        XCTAssertEqual(by["\(folder)/CLAUDE.local.md"]?.scope, "local")
        XCTAssertEqual(by["\(folder)/.claude/rules/api.md"]?.loading, .paths(["src/api/**", "lib/*.ts"]))
        XCTAssertEqual(by["\(folder)/.claude/rules/style.md"]?.loading, .always, "a rule without paths: loads every turn")
        XCTAssertEqual(by["\(folder)/ios/CLAUDE.md"]?.loading, .nested)
        XCTAssertEqual(found.filter { $0.path == "\(folder)/CLAUDE.md" }.count, 1, "the root CLAUDE.md isn't nested too")
        XCTAssertNil(by["/Users/CLAUDE.md"], "nothing above the home folder")
    }

    func testClaudeCodesOwnCountWinsOverTheEstimate() {
        let path = "\(folder)/CLAUDE.md"
        let estimated = scan([path: String(repeating: "a", count: 400)])[0]
        XCTAssertEqual(estimated.tokens, 100)
        XCTAssertFalse(estimated.isMeasured)
        XCTAssertFalse(estimated.isLoaded)
        let measured = scan([path: String(repeating: "a", count: 400)], measured: [path: 130])[0]
        XCTAssertEqual(measured.tokens, 130)
        XCTAssertTrue(measured.isLoaded)
    }

    func testOneLinePaths() {
        XCTAssertEqual(Sources.rulePaths("---\npaths: [\"a/**\", 'b/*.go']\n---\n"), ["a/**", "b/*.go"])
        XCTAssertEqual(Sources.rulePaths("paths: a/**\n"), [], "not frontmatter")
    }

    func testMemoryProblemsAreFoundAndAFutureLinkIsNot() {
        let index = """
        - [Profile](user.md) — who
        - [Gone](gone.md) — removed by hand
        """
        let files = [
            "user.md": "---\nname: user\ndescription: who\n---\nSee [[sql-order]] and [[later-idea]].",
            "sql_order.md": "---\nname: sql-order\ndescription: order by\n---\nbody",
        ]
        let memory = Sources.memory(folder: "/m", indexText: index, files: files)
        XCTAssertEqual(memory.entries.first { $0.file == "gone.md" }?.exists, false)
        XCTAssertEqual(memory.entries.first { $0.file == "sql_order.md" }?.isIndexed, false)
        XCTAssertEqual(memory.unwritten, ["later-idea"], "a link to a memory not written yet is kept, not flagged")
        let hints = Sources.hints([], memory: memory).map(\.text)
        XCTAssertTrue(hints.contains { $0.contains("gone.md") && $0.contains("gone") })
        XCTAssertTrue(hints.contains { $0.contains("sql_order.md isn't in MEMORY.md") })
        XCTAssertFalse(hints.contains { $0.contains("user.md") }, "an indexed, existing entry is fine")
    }

    func testHeavyAndPathlessInstructionsAreHinted() {
        let big = String(repeating: "a", count: 4 * Sources.heavyInstruction)
        let found = scan(["\(folder)/CLAUDE.md": big, "\(folder)/.claude/rules/x.md": String(repeating: "b", count: 4 * Sources.pathlessRuleHint),
                          "\(folder)/.claude/rules/tiny.md": "Commit in English.",
                          "\(folder)/.claude/rules/y.md": "---\npaths: src/**\n---\n" + big])
        let hints = Sources.hints(found, memory: nil).map(\.text)
        XCTAssertTrue(hints.contains { $0.hasPrefix("app/CLAUDE.md is ≈\(TokenFormat.short(Sources.heavyInstruction)) tokens") }, "\(hints)")
        XCTAssertTrue(hints.contains { $0.contains("Rule x.md has no paths:") })
        XCTAssertFalse(hints.contains { $0.contains("tiny.md") }, "a short rule for every file is fine without paths:")
        XCTAssertFalse(hints.contains { $0.contains("y.md") }, "a heavy rule with paths: costs nothing until it's needed")
    }

    func testALongIndexIsHinted() {
        let index = (1...250).map { "- [e\($0)](e\($0).md) — x" }.joined(separator: "\n")
        let memory = Sources.memory(folder: "/m", indexText: index, files: [:])
        XCTAssertTrue(Sources.hints([], memory: memory).contains { $0.text.contains("250 lines") })
    }

    func testDeletingAnEntryRemovesOnlyItsLine() {
        let index = "# Memory\n- [A](a.md) — x\n- [B](b.md) — y\n"
        XCTAssertEqual(Sources.removingIndexLines(of: "a.md", from: index), "# Memory\n- [B](b.md) — y\n")
    }
}

/// The panel's side: read off the main thread from the real files, a memory deleted, a rule made.
@MainActor
final class SourcesStoreTests: XCTestCase {
    func testTheSessionsSourcesAreReadAndChanged() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        let repo = try makeTempRepo()
        try "project rules".write(to: repo.appending(path: "CLAUDE.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: repo.appending(path: "ios"), withIntermediateDirectories: true)
        try "ios rules".write(to: repo.appending(path: "ios/CLAUDE.md"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        try store.addProject(at: repo)
        let project = store.projects[0]
        let memory = store.claudeHome.appending(path: "projects/\(ClaudeImport.claudeFolderName(for: project.path))/memory")
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        try "- [A](a.md) — x\n- [B](b.md) — y\n".write(to: memory.appending(path: "MEMORY.md"), atomically: true, encoding: .utf8)
        for name in ["a", "b"] {
            try "---\nname: \(name)\n---\n".write(to: memory.appending(path: "\(name).md"), atomically: true, encoding: .utf8)
        }
        try store.createSession(projectId: project.id!, model: nil, prompt: nil)
        let session = try XCTUnwrap(store.selectedSession)

        let read = await store.readSources(of: session)
        let sources = try XCTUnwrap(read)
        XCTAssertEqual(sources.instructions.map(\.path), ["\(repo.path)/CLAUDE.md", "\(repo.path)/ios/CLAUDE.md"])
        XCTAssertEqual(sources.instructions.last?.loading, .nested)
        let found = try XCTUnwrap(sources.memory)
        XCTAssertEqual(found.entries.map(\.file), ["a.md", "b.md"])

        store.deleteMemory(found.entries[0], in: found)
        let reread = await store.readSources(of: session)
        let after = try XCTUnwrap(reread?.memory)
        XCTAssertEqual(after.entries.map(\.file), ["b.md"], "its file and its index line are gone, the other stays")
        XCTAssertTrue(after.entries[0].exists && after.entries[0].isIndexed)

        store.newRule(named: "API handlers", in: sources.folder)
        let rule = try String(contentsOfFile: "\(repo.path)/.claude/rules/api-handlers.md", encoding: .utf8)
        XCTAssertEqual(Sources.rulePaths(rule), ["src/**"], "a new rule loads only for its paths, not every turn")
    }
}

/// The Context panel with its sources, at the popover's width, as a picture (MEEPO_SNAPSHOT_DIR).
@MainActor
final class SourcesPictureTests: XCTestCase {
    func testContextPanelPicture() async throws {
        let path = ProcessInfo.processInfo.environment["MEEPO_SNAPSHOT_DIR"]
        try XCTSkipIf(path == nil, "pictures only on request")
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        let repo = try makeTempRepo()
        try String(repeating: "Project rules. ", count: 700).write(to: repo.appending(path: "CLAUDE.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: repo.appending(path: ".claude/rules"), withIntermediateDirectories: true)
        try "---\npaths:\n  - \"Meepo/Views/**\"\n---\nTokens only.".write(to: repo.appending(path: ".claude/rules/ui.md"), atomically: true, encoding: .utf8)
        try "Always commit in English.".write(to: repo.appending(path: ".claude/rules/commits.md"), atomically: true, encoding: .utf8)
        try store.addProject(at: repo)
        let memory = store.claudeHome.appending(path: "projects/\(ClaudeImport.claudeFolderName(for: store.projects[0].path))/memory")
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        try "- [User profile](user.md) — Russian, explain devops simply\n- [SQL order](sql.md) — no ORDER BY, the plan decides\n"
            .write(to: memory.appending(path: "MEMORY.md"), atomically: true, encoding: .utf8)
        try "---\nname: user\n---\nSee [[guard-tests]].".write(to: memory.appending(path: "user.md"), atomically: true, encoding: .utf8)
        try "---\nname: old\ndescription: forgotten one\n---\n".write(to: memory.appending(path: "old.md"), atomically: true, encoding: .utf8)
        try store.createSession(projectId: store.projects[0].id!, model: nil, prompt: nil)

        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 340, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: ContextPanel().padding(14).frame(width: 340, height: 760, alignment: .top)
            .background(Tokens.surface).environment(store))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .seconds(1.5))
        let view = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path!).appending(path: "context-sources.png"))
    }
}
