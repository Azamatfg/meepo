import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import Meepo

/// The tester's crash on macOS 15 (2026-09-24/25): clicking between sessions traps on SwiftUI's DisplayLink
/// thread. This drives the real window the same way — several projects, live sessions, some waiting (pulsing
/// rings, "!"), selection hopping with its animation. Runs only where MEEPO_SMOKE=1 (the macos-15 CI job, with
/// a stand-in `claude` on PATH), so a developer Mac never starts real claude sessions in temp folders.
@MainActor
final class SessionSwitchSmokeTests: XCTestCase {
    func testClickingBetweenSessionsKeepsRunning() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MEEPO_SMOKE"] == "1", "macOS 15 CI smoke only")
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        for index in 0..<3 {
            let repo = try makeTempRepo()
            try git(["commit", "-q", "--allow-empty", "-m", "init \(index)"], in: repo)
            try store.addProject(at: repo)
        }
        for project in store.projects {
            try store.createSession(projectId: project.id!, model: nil, prompt: nil)
            try store.createSession(projectId: project.id!, model: nil, prompt: nil)
        }
        await store.resolveLogin()                                  // finds the stand-in claude
        XCTAssertNotNil(store.loginEnvironment, "stand-in claude not on the login shell's PATH")
        for session in store.sessions { store.startTerminalIfNeeded(session.id!) }
        // Half the units wait for the user: fast pulse and the hopping "!".
        for (i, session) in store.sessions.enumerated() where i.isMultiple(of: 2) {
            store.handleHookEvent(HookPayload(event: "PermissionRequest", claudeSessionId: session.claudeSessionId,
                                              toolName: "Bash", toolTarget: "rm -rf build"), sessionId: session.id!)
        }

        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1280, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: MainView().environment(store))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Option+Tab as the tester does it: single presses, then held down (key repeat ~30 ms), and clicks.
        let ids = store.orderedSessions.compactMap(\.id)
        for step in 0..<150 {
            // A narrow window too: the stage bar then no longer fits (the tester's crash was in its fitting).
            if step.isMultiple(of: 25) {
                window.setContentSize(NSSize(width: step.isMultiple(of: 50) ? 1060 : 1280, height: 800))
            }
            if step % 50 < 20 {
                store.selectSession(offset: 1)                       // Option+Tab
                try await Task.sleep(for: .milliseconds(300))
            } else if step % 50 < 40 {
                store.selectSession(offset: step.isMultiple(of: 2) ? 1 : -1)   // held down
                try await Task.sleep(for: .milliseconds(30))
            } else {
                store.selectedSessionId = ids[step % ids.count]     // a click on a card
                try await Task.sleep(for: .milliseconds(120))
            }
        }
        window.orderOut(nil)
        XCTAssertEqual(store.sessions.count, 6)                     // still alive
    }
}
