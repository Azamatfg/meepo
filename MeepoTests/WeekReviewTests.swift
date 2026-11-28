import GRDB
import SwiftUI
import XCTest
@testable import Meepo

/// Home: where the week's work went, per project, and what the review is given to read.
@MainActor
final class WeekReviewTests: XCTestCase {
    func testWorkIsCountedPerProjectForTodayAndTheWeek() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        try store.addProject(at: try makeTempRepo())
        let project = store.projects[0]
        try store.createSession(projectId: project.id!, model: nil, prompt: nil)
        let session = store.sessions[0]
        let now = Date.now, lastWeek = now.addingTimeInterval(-3 * 86400), old = now.addingTimeInterval(-9 * 86400)
        _ = session
        // As history.jsonl has them: where claude ran — the project, a folder inside it, another project.
        let entries = [now, now, lastWeek, old].map { Noticing.Entry(display: "x", date: $0, session: "s", project: project.path) }
            + [Noticing.Entry(display: "y", date: now, session: "s", project: project.path + "/backend"),
               Noticing.Entry(display: "z", date: now, session: "s", project: project.path + "-other")]
        try db.write { db in
            try db.execute(sql: "INSERT INTO task (projectId, text, createdAt, isDone, doneAt, status) VALUES (?, 'a', ?, 1, ?, 'active'), (?, 'b', ?, 1, ?, 'active')",
                           arguments: [project.id, old, now, project.id, old, old])
        }
        let week = store.workWeek(now: now, entries: entries)
        let row = try XCTUnwrap(week.first { $0.project == project.name })
        XCTAssertEqual(row.promptsToday, 3, "a folder inside counts; a sibling folder sharing the name's start doesn't")
        XCTAssertEqual(row.promptsWeek, 4, "the prompt 9 days ago is outside the week")
        XCTAssertEqual(row.tasksDoneWeek, 1)
    }

    func testStackSignalsReadTheProjectsFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "stack-\(UUID().uuidString)")
        for file in ["go.mod", "Dockerfile", "docker-compose.yml", ".github/workflows/ci.yml", "internal/x_test.go", "CLAUDE.md"] {
            let url = root.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "line\n".write(to: url, atomically: true, encoding: .utf8)
        }
        let signals = TechStack.signals(at: root.path)
        for expected in ["Go", "Dockerfile", "docker compose", "GitHub Actions", "tests", "CLAUDE.md 1 lines"] {
            XCTAssertTrue(signals.contains(expected), "\(expected) in \(signals)")
        }
        XCTAssertFalse(signals.contains("Kubernetes"))
    }

    func testBehaviorIsSummedForTheWeek() {
        let now = Date.now
        let lines = [
            BehaviorLog.line("key", ["key": "esc", "in": "T"], at: now),
            BehaviorLog.line("key", ["key": "esc", "in": "T"], at: now.addingTimeInterval(-10 * 86400)),
            BehaviorLog.line("hook", ["event": "PermissionRequest", "project": "taxi"], at: now),
            BehaviorLog.line("hook", ["event": "UserPromptSubmit", "project": "taxi"], at: now),
        ].joined(separator: "\n")
        let habits = WeekReview.habits(from: lines, since: now.addingTimeInterval(-7 * 86400))
        XCTAssertEqual(habits["interrupts (Esc)"], 1, "the one 10 days ago is outside the week")
        XCTAssertEqual(habits["permission requests"], 1)
        XCTAssertEqual(habits["prompts"], 1)
    }

    /// The review is Opus's, once a week, reading the week's busiest projects — read-only.
    func testReviewRunsOnOpusReadingTheBusiestProjects() {
        let work = (1...8).map { ProjectWork(project: "p\($0)", promptsWeek: 10 - $0) } + [ProjectWork(project: "idle")]
        let folders = Dictionary(uniqueKeysWithValues: work.map { ($0.project, ["/w/\($0.project)"]) })
        let args = WeekReview.arguments(work: work, folders: folders)
        XCTAssertEqual(args.model, "opus")
        XCTAssertEqual(args.tools, "Read,Grep,Glob,WebSearch,WebFetch", "it reads and searches, never writes or runs")
        XCTAssertEqual(Array(args.extra.prefix(4)), ["--allowedTools", "WebSearch WebFetch", "--add-dir", WeekReview.changelog],
                       "what Claude Code shipped lately is readable too")
        XCTAssertEqual(args.extra.dropFirst(4).filter { $0 != "--add-dir" }, (1...6).map { "/w/p\($0)" }, "the 6 busiest; none without prompts")
        XCTAssertEqual(WeekReview.refreshEvery, 7 * 86400)
    }

    /// ~/Projects/taxi holds links to its repos, and Glob doesn't follow links: the repos are given too.
    func testLinkedReposAreReadableToo() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "links-\(UUID().uuidString)")
        let repo = root.appending(path: "repos/backend"), project = root.appending(path: "taxi")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: project.appending(path: "backend"), withDestinationURL: repo)
        try FileManager.default.createSymbolicLink(at: project.appending(path: "gone"), withDestinationURL: root.appending(path: "nowhere"))
        try "x".write(to: project.appending(path: "README.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(WeekReview.readableFolders(of: project.path), [project.path, repo.resolvingSymlinksInPath().path])
    }

    /// The schema the model answers to, as Meepo decodes it: principles with their source, tech naming its principle.
    func testTheSchemaAndTheModelAgree() throws {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(WeekReview.schema.utf8)) as? [String: Any])
        XCTAssertEqual(Set(schema["required"] as? [String] ?? []), ["summary", "principles", "claudeCode", "tech"])
        let json = Data(#"{"summary":"s","principles":[{"name":"n","who":"w","why":"y","source":"https://x","inYourWork":"i","step":"st"}],"claudeCode":[],"tech":[{"project":"p","title":"t","verdict":"now","why":"w","tryThis":"x","principle":"n"}]}"#.utf8)
        let review = try JSONDecoder().decode(WeekReview.self, from: json)
        XCTAssertEqual(review.principles?.first?.source, "https://x")
        XCTAssertEqual(review.tech.first?.principle, "n")
    }

    func testAReviewDecodes() throws {
        let json = Data(#"{"summary":"s","claudeCode":[{"title":"t","why":"w","tryThis":"x"}],"tech":[{"project":"taxi","title":"Kubernetes","verdict":"not yet","why":"w","tryThis":"x"}]}"#.utf8)
        let review = try JSONDecoder().decode(WeekReview.self, from: json)
        XCTAssertEqual(review.tech.first?.verdict, "not yet")
    }

    /// Home as a picture, dark, on this Mac's real ~/.claude files (MEEPO_SNAPSHOT_DIR, as ShellSnapshotTests).
    func testHomePicture() async throws {
        let path = ProcessInfo.processInfo.environment["MEEPO_SNAPSHOT_DIR"]
        try XCTSkipIf(path == nil, "pictures only on request")
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1500, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: WorkHome().frame(width: 1500, height: 900).background(Tokens.ground).environment(store))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .seconds(2))
        let view = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path!).appending(path: "home.png"))
    }
}
