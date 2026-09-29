import GRDB
import XCTest
@testable import Meepo

@MainActor
final class TabOrderTests: XCTestCase {
    private var db: DatabaseQueue!
    private var defaults: UserDefaults!
    private var store: AppStore!

    override func setUp() async throws {
        db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        defaults = UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!
        store = makeStore()
        try store.addProject(at: try makeTempRepo())
        try store.addProject(at: try makeTempRepo())
    }

    private func makeStore() -> AppStore {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "store-\(UUID().uuidString)")
        return AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "settings.json"), meepoHome: tmp),
                        usageRoot: tmp, defaults: defaults)
    }

    private func newSession(in project: Int) throws -> Int64 {
        try store.createSession(projectId: store.projects[project].id!, model: nil, prompt: nil)
        return store.selectedSessionId!
    }

    private var tabs: [Int64] { store.orderedSessions.map { $0.id! } }

    /// A dragged order holds across projects and survives a restart.
    func testDraggedOrderStaysAfterRestart() throws {
        let (a1, a2, b1) = (try newSession(in: 0), try newSession(in: 0), try newSession(in: 1))
        XCTAssertEqual(tabs, [a1, a2, b1], "never dragged: by project, oldest first")
        store.moveTab(b1, onto: a1)
        XCTAssertEqual(tabs, [b1, a1, a2])
        store.moveTab(b1, onto: a2)
        XCTAssertEqual(tabs, [a1, a2, b1], "dragged right: it lands after the tab it was dropped on")
        store.moveTab(a2, onto: a1)
        store = makeStore()
        XCTAssertEqual(tabs, [a2, a1, b1])
    }

    /// Opened after a drag: next to its project's latest session, not at the far end or the front.
    func testNewSessionGoesAfterItsProjectsLatest() throws {
        let (a1, b1) = (try newSession(in: 0), try newSession(in: 1))
        store.moveTab(b1, onto: a1) // [b1, a1]
        let b2 = try newSession(in: 1)
        XCTAssertEqual(tabs, [b1, b2, a1])
    }

    /// A shell opened beside a session still sits right after it once the tabs were dragged.
    func testShellBesideStaysNextToItsSessionAfterADrag() throws {
        let (a1, b1) = (try newSession(in: 0), try newSession(in: 1))
        store.moveTab(b1, onto: a1) // [b1, a1]
        try store.saveServer(Server(projectId: store.projects[1].id!, host: "prod"))
        store.shellsBeside = true
        store.selectedSessionId = b1
        try store.openShell(on: store.servers[0])
        XCTAssertEqual(tabs, [b1, store.selectedSessionId!, a1])
    }
}
