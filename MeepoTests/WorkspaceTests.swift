import GRDB
import SwiftUI
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
        XCTAssertFalse(store.showsEverything, "hidden by default")
        XCTAssertEqual(store.shownShell.left, [.explorer])
        XCTAssertTrue(store.shownShell.bottom.isEmpty)
        XCTAssertEqual(store.railPanels, [.sessions, .explorer, .tasks, .context])
        XCTAssertEqual(store.shell.bottom, [.events, .ci], "the arrangement itself stays")

        store.showsEverything = true
        XCTAssertEqual(store.shownShell, store.shell)
        XCTAssertEqual(store.railPanels, ShellLayout.Panel.allCases)
    }
}

/// Workspaces set up in one place (2026-11-28): renamed and removed whole, and suggested from the projects' names.
@MainActor
final class WorkspaceSetupTests: XCTestCase {
    func testRenameAndRemoveTakeEveryProjectAlong() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        for _ in 0..<2 { try store.addProject(at: try makeTempRepo()) }
        let ids = store.projects.compactMap(\.id)
        for id in ids { store.setWorkspace(id, to: "Work") }
        store.workspace = "Work"
        store.renameWorkspace("Work", to: "alva")
        XCTAssertEqual(store.workspaceNames, ["alva"])
        XCTAssertEqual(store.workspace, "alva", "the one shown follows its new name")
        store.removeWorkspace("alva")
        XCTAssertTrue(store.workspaceNames.isEmpty)
        XCTAssertNil(store.workspace)
        XCTAssertEqual(store.projects.count, 2, "projects stay; only the grouping goes")
    }

    func testGroupsAreSuggestedFromSharedWordsInNames() {
        let names = ["taxi", "taxinet", "taxi-kolesa", "regional taxi", "alva", "powerbanks", "meepo", "career"]
        let suggested = AppStore.suggestedWorkspaces(names)
        XCTAssertEqual(suggested["taxi"].map(Set.init), ["taxi", "taxinet", "taxi-kolesa", "regional taxi"])
        XCTAssertEqual(suggested.count, 1, "a name shared by nobody else isn't a group")
    }

    /// The sheet and the title bar's switcher as pictures (MEEPO_SNAPSHOT_DIR, as ShellSnapshotTests).
    func testWorkspacesPicture() async throws {
        let path = ProcessInfo.processInfo.environment["MEEPO_SNAPSHOT_DIR"]
        try XCTSkipIf(path == nil, "pictures only on request")
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        let base = FileManager.default.temporaryDirectory.appending(path: "ws-\(UUID().uuidString)")
        for name in ["taxi", "taxinet", "taxi-kolesa", "regional taxi", "alva", "powerbanks", "meepo", "career"] {
            let repo = try makeTempRepo()
            let named = base.appending(path: name)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: repo, to: named)
            try store.addProject(at: named)
        }
        store.setWorkspace(store.projects.first { $0.name == "alva" }!.id!, to: "alva")
        for (view, size, file) in [(AnyView(WorkspacesSheet()), NSSize(width: 720, height: 600), "workspaces.png"),
                                   (AnyView(WorkspaceChip().padding(10)), NSSize(width: 220, height: 50), "workspace-chip.png")] {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: view.background(Tokens.ground).environment(store))
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .seconds(1))
            let content = try XCTUnwrap(window.contentView)
            let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path!).appending(path: file))
            window.orderOut(nil)
        }
    }
}

/// Tasks belong to a workspace: their own, else their project's; moved many at once (2026-11-28).
@MainActor
final class WorkspaceTasksTests: XCTestCase {
    func testTasksFollowTheWorkspaceAndMoveTogether() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        try store.addProject(at: try makeTempRepo())
        let alva = store.projects[0].id!
        store.setWorkspace(alva, to: "alva")
        let inProject = try XCTUnwrap(store.addTask("deploy", projectId: alva))
        let loose = try XCTUnwrap(store.addTask("read SRE book", projectId: nil))
        XCTAssertEqual(store.workspace(of: inProject), "alva", "a project's task is in its project's workspace")
        XCTAssertNil(store.workspace(of: loose))

        store.workspace = "taxi-free"  // a name with no projects isn't kept; set the real one
        store.workspace = "alva"
        XCTAssertEqual(store.workspaceTasks.map(\.text), ["deploy"], "the loose one isn't alva's")
        let typed = try XCTUnwrap(store.addTask("call the driver team", projectId: nil))
        XCTAssertEqual(typed.workspace, "alva", "typed while alva is shown: it's alva's")

        store.moveTasks([loose.id!, inProject.id!], toWorkspace: "taxi")
        XCTAssertEqual(Set(store.tasks.compactMap { store.workspace(of: $0) }), ["taxi", "alva"])
        XCTAssertEqual(store.tasks.first { $0.text == "deploy" }.flatMap { store.workspace(of: $0) }, "taxi",
                       "its own workspace wins over its project's")
        XCTAssertTrue(store.workspaceNames.contains("taxi"), "a workspace with tasks only is offered too")
        store.renameWorkspace("taxi", to: "taxi work")
        XCTAssertEqual(store.tasks.filter { $0.workspace == "taxi work" }.count, 2, "its tasks follow the new name")
        store.workspace = nil
        XCTAssertEqual(store.workspaceTasks.count, 3, "All shows every task")
    }
}

/// Everything on screen follows the workspace shown (2026-11-28: Home and the status bar didn't).
@MainActor
final class WorkspaceScopeTests: XCTestCase {
    private func store() throws -> (AppStore, alva: Int64, taxi: Int64) {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        for _ in 0..<2 { try store.addProject(at: try makeTempRepo()) }
        let (alva, taxi) = (store.projects[0].id!, store.projects[1].id!)
        store.setWorkspace(alva, to: "alva")
        store.setWorkspace(taxi, to: "taxi")
        return (store, alva, taxi)
    }

    func testOpeningASessionOfAnotherWorkspaceShowsThatWorkspace() throws {
        let (store, alva, taxi) = try store()
        try store.createSession(projectId: alva, model: nil, prompt: nil)
        try store.createSession(projectId: taxi, model: nil, prompt: nil)
        let taxiSession = store.sessions.first { $0.projectId == taxi }!.id!
        store.workspace = "alva"
        store.selectedSessionId = taxiSession // a notification's click, Ctrl+Tab
        XCTAssertEqual(store.workspace, "taxi", "its tab must be on screen")
        XCTAssertEqual(store.selectedSessionId, taxiSession)
    }

    func testCtrlTabReachesTheOneWaitingInAnotherWorkspace() throws {
        let (store, alva, taxi) = try store()
        try store.createSession(projectId: alva, model: nil, prompt: nil)
        try store.createSession(projectId: taxi, model: nil, prompt: nil)
        var waiting = store.sessions.first { $0.projectId == taxi }!
        waiting.status = .waitingInput
        _ = store.handleHookEvent(HookPayload(event: "Notification", claudeSessionId: waiting.claudeSessionId,
                                              notificationType: "idle_prompt"), sessionId: waiting.id!)
        store.workspace = "alva"
        XCTAssertEqual(store.waitingHere.here, 0)
        XCTAssertEqual(store.waitingHere.elsewhere, 1)
        store.selectNextWaiting()
        XCTAssertEqual(store.selectedSessionId, waiting.id)
        XCTAssertEqual(store.workspace, "taxi")
    }

    func testTheWeekOnHomeIsTheWorkspaces() throws {
        let (store, alva, taxi) = try store()
        let paths = Dictionary(uniqueKeysWithValues: store.projects.map { ($0.id!, $0.path) })
        let entries = [Noticing.Entry(display: "a", date: .now, session: nil, project: paths[alva]),
                       Noticing.Entry(display: "t", date: .now, session: nil, project: paths[taxi]),
                       Noticing.Entry(display: "t2", date: .now, session: nil, project: paths[taxi])]
        store.workspace = "taxi"
        XCTAssertEqual(store.inWorkspace(entries).map(\.display), ["t", "t2"])
        XCTAssertEqual(store.workWeek(entries: store.inWorkspace(entries)).map(\.project), [store.projects.first { $0.id == taxi }!.name])
        store.workspace = nil
        XCTAssertEqual(store.inWorkspace(entries).count, 3)
    }
}
