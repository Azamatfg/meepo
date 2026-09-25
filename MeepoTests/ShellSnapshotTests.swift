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
        UserDefaults.standard.set("timeline", forKey: "homeView")
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
    }
}
