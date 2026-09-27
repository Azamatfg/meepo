import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import Meepo

/// Pictures of the window in each layout, for looking at by eye. Runs only with MEEPO_SNAPSHOT_DIR set
/// (TEST_RUNNER_MEEPO_SNAPSHOT_DIR=… xcodebuild test); no claude starts — terminals show "Starting claude…".
@MainActor
final class ShellSnapshotTests: XCTestCase {
    func testLayouts() async throws {
        let path = ProcessInfo.processInfo.environment["MEEPO_SNAPSHOT_DIR"]
        try XCTSkipIf(path == nil, "pictures only on request")
        let dir = URL(fileURLWithPath: path!)
        // Tests share the app's defaults; put back what the pictures change.
        let homeView = UserDefaults.standard.string(forKey: "homeView")
        defer { UserDefaults.standard.set(homeView, forKey: "homeView") }
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "snap-\(UUID().uuidString)")
        let store = AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "s.json"), meepoHome: tmp),
                             usageRoot: tmp, defaults: UserDefaults(suiteName: "meepo-snap-\(UUID().uuidString)")!)
        for index in 0..<3 {
            let repo = try makeTempRepo()
            try git(["commit", "-q", "--allow-empty", "-m", "init \(index)"], in: repo)
            try "change".write(to: repo.appending(path: "notes.md"), atomically: true, encoding: .utf8)
            try store.addProject(at: repo)
        }
        for project in store.projects { try store.createSession(projectId: project.id!, model: "opus", prompt: nil) }
        let sessions = store.sessions
        store.handleHookEvent(HookPayload(event: "PermissionRequest", claudeSessionId: sessions[1].claudeSessionId,
                                          toolName: "Bash", toolTarget: "pytest tests -q"), sessionId: sessions[1].id!)
        store.handleHookEvent(HookPayload(event: "UserPromptSubmit", claudeSessionId: sessions[0].claudeSessionId,
                                          prompt: "run the tests"), sessionId: sessions[0].id!)
        store.selectedSessionId = sessions[0].id
        // A finished run with its product summary, for the What changed panel.
        let started = Date.now.addingTimeInterval(-600)
        try await db.write { db in
            for (name, summary, second) in [("UserPromptSubmit", "add refunds for Kaspi payments", 0.0),
                                            ("PostToolUse", "Edit: /repo/Refund.swift", 60), ("Stop", "Done.", 300)] {
                var event = HookEvent(sessionId: sessions[0].id!, name: name, summary: summary, isFailure: false,
                                      createdAt: started.addingTimeInterval(second))
                try event.insert(db)
            }
            try db.execute(sql: "INSERT INTO runSummary (sessionId, startedAt, json, createdAt) VALUES (?, ?, ?, ?)", arguments: [
                sessions[0].id!, started,
                #"{"headline":"Drivers can refund a Kaspi payment","changes":[{"kind":"new","what":"A Refund button on a paid trip","where":"Driver app → Trips → Payment"},{"kind":"changed","what":"Refunds show in the daily report","where":"Admin → Finance"}],"check":["Refunds over 50 000 ₸ need a manager's OK — intended?"],"how_to_try":"Open a paid trip in the driver app and press Refund."}"#,
                Date.now])
        }

        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1440, height: 900),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: MainView().environment(store))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        func shoot(_ name: String) async throws {
            try await Task.sleep(for: .milliseconds(700))
            let view = try XCTUnwrap(window.contentView)
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(name).png"))
        }

        for preset in [ShellLayout.Preset.focus, .deck, .full] {
            store.applyPreset(preset)
            try await shoot(preset.rawValue)
        }
        store.isHomeShown = true
        UserDefaults.standard.set("deck", forKey: "homeView")
        try await shoot("home-deck")
        UserDefaults.standard.set("today", forKey: "homeView")
        try await shoot("home-timeline")
        window.setContentSize(NSSize(width: 1060, height: 640))
        store.selectedSessionId = sessions[0].id
        store.applyPreset(.full)
        try await shoot("full-narrow")
    }

    /// Automations on this Mac's real history and skills — read only; the window's store has a temp settings file.
    func testAutomations() async throws {
        let path = ProcessInfo.processInfo.environment["MEEPO_SNAPSHOT_DIR"]
        try XCTSkipIf(path == nil, "pictures only on request")
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "snapa-\(UUID().uuidString)")
        let store = AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "s.json"), meepoHome: tmp),
                             usageRoot: tmp, defaults: UserDefaults(suiteName: "meepo-snap-\(UUID().uuidString)")!)
        try store.addProject(at: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()) // this repo
        try store.makeButton(named: "tidy-ship", steps: [.command("simplify"), .command("commit-push-pr")])
        try store.addCheck("swift test", in: nil)
        store.refreshProjects()
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 980, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: AutomationsView().environment(store))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .seconds(4))
        let view = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path!).appending(path: "automations.png"))

        let sheet = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 720, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.contentView = NSHostingView(rootView: WorkflowSheet(project: store.projects[0]).environment(store))
        sheet.makeKeyAndOrderFront(nil)
        defer { sheet.orderOut(nil) }
        try await Task.sleep(for: .seconds(2))
        let sheetView = try XCTUnwrap(sheet.contentView)
        let sheetRep = try XCTUnwrap(sheetView.bitmapImageRepForCachingDisplay(in: sheetView.bounds))
        sheetView.cacheDisplay(in: sheetView.bounds, to: sheetRep)
        try sheetRep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path!).appending(path: "workflow-sheet.png"))
    }

    func testPipeline() async throws {
        let path = ProcessInfo.processInfo.environment["MEEPO_SNAPSHOT_DIR"]
        try XCTSkipIf(path == nil, "pictures only on request")
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        let now = Date.now
        func shot(_ steps: [Pipeline.Step], _ file: String) async throws {
            let pipeline = Pipeline(branch: "master", sha: "d015346b", steps: steps, title: "fix: loans recalculation")
            let view = PipelineView(pipeline: pipeline, runs: [], project: nil, name: "taxinet", confirm: { _ in }, start: { _ in })
                .padding(14).frame(width: 300, alignment: .topLeading).background(Tokens.surface).environment(store)
            let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 300, height: 330), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: view)
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .seconds(1.5))
            let content = try XCTUnwrap(window.contentView)
            let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path!).appending(path: file))
        }
        try await shot([
            Pipeline.Step(name: "CI", state: .passed, url: "https://x", started: now - 400, finished: now - 250),
            Pipeline.Step(name: "Build & Push", state: .running, url: "https://x", started: now - 149),
            Pipeline.Step(name: "Deploy", state: .manual, trigger: "deploy.yml"),
        ], "pipeline-running.png")
        try await shot([
            Pipeline.Step(name: "CI", state: .passed, url: "https://x", started: now - 400, finished: now - 250),
            Pipeline.Step(name: "Build & Push", state: .passed, url: "https://x", started: now - 249, finished: now - 60),
            Pipeline.Step(name: "Deploy", state: .manual, trigger: "deploy.yml"),
        ], "pipeline-ready.png")
    }

    func testOnboarding() async throws {
        let path = ProcessInfo.processInfo.environment["MEEPO_SNAPSHOT_DIR"]
        try XCTSkipIf(path == nil, "pictures only on request")
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "snapo-\(UUID().uuidString)")
        let store = AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "s.json"), meepoHome: tmp),
                             usageRoot: tmp, defaults: UserDefaults(suiteName: "meepo-snap-\(UUID().uuidString)")!)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 820, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: OnboardingView().environment(store))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .seconds(1))
        let view = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path!).appending(path: "onboarding.png"))
    }

    /// The README's screenshots: demo mode's made-up projects in each layout, at 1440 × 900.
    /// TEST_RUNNER_MEEPO_SCREENSHOT_DIR=docs/screenshots xcodebuild test -only-testing:MeepoTests/ShellSnapshotTests/testDemoScreens
    /// A view's whole layer tree at 2×, as a picture.
    static func render(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()

        let scale: CGFloat = 2, size = view.bounds.size
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        // The rep's context already maps points to its 2× pixels; layers draw top-down, the bitmap bottom-up.
        let cg = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep)).cgContext
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        try XCTUnwrap(view.layer).render(in: cg)
        // The terminals' own background (their layer's) doesn't come through a render — only their text, over a
        // clear hole. Laid over the terminal color meepo gives them, they look as they do on screen.
        let page = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let out = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: page)).cgContext
        let whole = CGRect(x: 0, y: 0, width: page.pixelsWide, height: page.pixelsHigh)
        out.setFillColor(NSColor(Tokens.terminalBg).cgColor)
        out.fill(whole)
        out.draw(try XCTUnwrap(rep.cgImage), in: whole)
        return page
    }

    func testDemoScreens() async throws {
        let path = ProcessInfo.processInfo.environment["MEEPO_SCREENSHOT_DIR"]
        try XCTSkipIf(path == nil, "screenshots only on request")
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "demo-\(UUID().uuidString)")
        let store = AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "s.json"), meepoHome: tmp),
                             usageRoot: tmp, defaults: UserDefaults(suiteName: "meepo-demo-\(UUID().uuidString)")!)
        await store.loadDemo()
        let homeView = UserDefaults.standard.string(forKey: "homeView")
        defer { UserDefaults.standard.set(homeView, forKey: "homeView") }
        // A fresh window per picture: terminals resized inside a window already on screen came out black here.
        func shoot(_ name: String) async throws {
            let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1440, height: 900),
                                  styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(rootView: MainView().environment(store))
            // The test host runs as a background app; macOS may draw its windows dimmed. Pictures want it in front.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil }
            try await Task.sleep(for: .milliseconds(1500))
            // Drawn by the app itself, layers and all: no Screen Recording permission, nothing the window server
            // adds (a permission-less capture comes back dimmed; cacheDisplay leaves layer backgrounds out).
            // A terminal that was just made or resized paints its background only after it has drawn once.
            _ = try Self.render(try XCTUnwrap(window.contentView))
            try await Task.sleep(for: .milliseconds(700))
            let rep = try Self.render(try XCTUnwrap(window.contentView))
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path!).appending(path: "\(name).png"))
        }
        store.applyPreset(.deck)
        try await shoot("deck")
        store.applyPreset(.focus)
        try await shoot("focus")
        store.applyPreset(.full)
        try await shoot("full")
        store.isHomeShown = true
        UserDefaults.standard.set("deck", forKey: "homeView")
        try await shoot("home")
        UserDefaults.standard.set("today", forKey: "homeView")
        try await shoot("today")
    }
}
