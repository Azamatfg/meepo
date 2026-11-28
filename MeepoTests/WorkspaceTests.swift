import GRDB
import XCTest
@testable import Meepo

/// Workspaces: projects grouped by where the work is (personal, a job, a client); one shown at a time, or all.
@MainActor
final class WorkspaceTests: XCTestCase {
    private var store: AppStore!

    override func setUp() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        store = makeIsolatedStore(db: db)
    }

    private func addProject(_ name: String) throws -> Int64 {
        let repo = try makeTempRepo()
        let named = repo.deletingLastPathComponent().appending(path: "\(name)-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: repo, to: named)
        try store.addProject(at: named)
        return store.projects.first { $0.name.hasPrefix(name + "-") }!.id!
    }

    func testAWorkspaceShowsOnlyItsProjectsAndTheirTabs() throws {
        let (meepo, alva) = (try addProject("meepo"), try addProject("alva"))
        try store.createSession(projectId: meepo, model: nil, prompt: nil)
        try store.createSession(projectId: alva, model: nil, prompt: nil)
        store.setWorkspace(alva, to: "Work")
        XCTAssertEqual(store.workspaceNames, ["Work"])
        XCTAssertEqual(store.workspaceProjects.count, 2, "All until one is picked")

        store.workspace = "Work"
        XCTAssertEqual(store.workspaceProjects.map(\.id), [alva])
        XCTAssertEqual(store.orderedSessions.map(\.projectId), [alva], "the tabs follow the sidebar")
        XCTAssertEqual(store.selectedSession?.projectId, alva, "a session of a hidden project doesn't stay selected")

        store.workspace = nil
        XCTAssertEqual(Set(store.orderedSessions.map(\.projectId)), [meepo, alva])
    }

    func testEmptiedWorkspaceFallsBackToAll() throws {
        let alva = try addProject("alva")
        store.setWorkspace(alva, to: "Work")
        store.workspace = "Work"
        store.setWorkspace(alva, to: nil)
        XCTAssertNil(store.workspace, "no project left in it: nothing would show")
        XCTAssertTrue(store.workspaceNames.isEmpty)
    }
}

/// What the user doesn't use (2026-11-28: Source Control, CI, Events, Needs you, What changed) stays out of sight
/// until Settings brings it back; the layout the user arranged is kept as it was.
@MainActor
final class HiddenPanelsTests: XCTestCase {
    func testHiddenPanelsLeaveTheLayoutAndTheRail() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        store.applyPreset(.full)
        XCTAssertFalse(store.showsAllPanels, "hidden by default")
        XCTAssertEqual(store.shownShell.left, [.explorer])
        XCTAssertTrue(store.shownShell.bottom.isEmpty)
        XCTAssertEqual(store.railPanels, [.sessions, .explorer, .tasks])
        XCTAssertEqual(store.shell.bottom, [.events, .ci], "the arrangement itself stays")

        store.showsAllPanels = true
        XCTAssertEqual(store.shownShell, store.shell)
        XCTAssertEqual(store.railPanels, ShellLayout.Panel.allCases)
    }
}
