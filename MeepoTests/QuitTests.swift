import GRDB
import XCTest
@testable import Meepo

@MainActor
final class QuitTests: XCTestCase {
    private var db: DatabaseQueue!
    private var store: AppStore!
    private var defaults: UserDefaults!
    private var quits = 0

    override func setUp() async throws {
        db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        defaults = UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!
        store = makeStore()
        try store.addProject(at: try makeTempRepo())
        try store.createSession(projectId: store.projects[0].id!, model: nil, prompt: nil)
    }

    private func makeStore() -> AppStore {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "quit-\(UUID().uuidString)")
        let store = AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "s.json"), meepoHome: tmp),
                             usageRoot: tmp, defaults: defaults)
        store.terminate = { [weak self] in self?.quits += 1 }
        return store
    }

    private var session: Session { store.sessions[0] }

    private func working() {
        store.handleHookEvent(HookPayload(event: "UserPromptSubmit", claudeSessionId: session.claudeSessionId, prompt: "go"),
                              sessionId: session.id!)
    }

    func testNobodyWorkingQuitsRightAway() {
        XCTAssertTrue(store.shouldQuit())
        XCTAssertNil(store.confirmation)
    }

    func testAWorkingAgentIsAskedAbout() {
        working()
        XCTAssertFalse(store.shouldQuit(), "a turn in progress would be cut off")
        XCTAssertEqual(store.confirmation?.title, "An agent is still working")
        store.confirmation?.perform() // Quit now
        XCTAssertEqual(quits, 1)
        XCTAssertTrue(store.shouldQuit(), "once confirmed, the real quit goes through")
    }

    func testQuitWhenTheyFinishWaitsForTheLastStop() {
        working()
        _ = store.shouldQuit()
        store.confirmation?.alternative?.perform()
        XCTAssertEqual(quits, 0)
        store.handleHookEvent(HookPayload(event: "Stop", claudeSessionId: session.claudeSessionId), sessionId: session.id!)
        XCTAssertEqual(quits, 1)
    }

    func testCancellingARestartForgetsIt() {
        working()
        store.relaunchAfterQuit = true
        _ = store.shouldQuit()
        store.confirmation?.onCancel?()
        XCTAssertFalse(store.relaunchAfterQuit, "a later ordinary quit must not reopen Meepo")
    }

    func testATurnCutOffByQuittingShowsUpNextTime() throws {
        working()
        let again = makeStore()                                      // Meepo opens again on the same database
        XCTAssertTrue(again.interruptedSessionIds.contains(session.id!))
        again.handleHookEvent(HookPayload(event: "SessionStart", claudeSessionId: session.claudeSessionId), sessionId: session.id!)
        XCTAssertFalse(again.interruptedSessionIds.contains(session.id!), "any sign of life clears it")
    }
}

final class CrashReportTests: XCTestCase {
    func testOnlyMeepoReportsNewerThanTheLastSeen() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func report(_ name: String, age: TimeInterval) throws -> URL {
            let url = dir.appending(path: name)
            try "report".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-age)], ofItemAtPath: url.path)
            return url
        }
        _ = try report("Meepo-2026-09-24-old.ips", age: 7200)
        let fresh = try report("Meepo-2026-09-25-new.ips", age: 60)
        _ = try report("Safari-2026-09-25.ips", age: 10)
        _ = try report("Meepo-notes.txt", age: 10)
        XCTAssertEqual(CrashReports.latest(since: .now.addingTimeInterval(-3600), in: dir)?.lastPathComponent, fresh.lastPathComponent)
        XCTAssertNil(CrashReports.latest(since: .now, in: dir), "dismissed ones don't come back")
    }
}
