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

    /// A pane dropped on another by its header: just those two trade places, the rest stay put.
    func testPanesSwapWithoutMovingTheOthers() throws {
        let (a1, a2, a3) = (try newSession(in: 0), try newSession(in: 0), try newSession(in: 0))
        store.swapTabs(a1, a3)
        XCTAssertEqual(tabs, [a3, a2, a1], "a move would give [a2, a3, a1] or [a3, a1, a2]")
        XCTAssertEqual(AppStore.draggedTab([AppStore.tabDragPrefix + String(a2)]), a2)
        XCTAssertNil(AppStore.draggedTab(["explorer"]), "a dragged panel isn't a tab")
    }

    /// On screen, the two panes trade places and the third stays: the grid follows the tabs, not the selected one.
    func testSwappedPanesTradePlacesInTheGrid() throws {
        store.applyPreset(.deck) // four panes, three sessions
        let (a1, a2, b1) = (try newSession(in: 0), try newSession(in: 0), try newSession(in: 1))
        store.selectedSessionId = b1 // the last one: the grid still starts at the first tab, not rotated to it
        XCTAssertEqual(store.visibleSessionIds, [a1, a2, b1])
        store.swapTabs(a2, a1)
        XCTAssertEqual(store.visibleSessionIds, [a2, a1, b1], "not rotated to start at the selected b1")
        store.swapTabs(b1, a2)
        XCTAssertEqual(store.visibleSessionIds, [b1, a2, a1], "two projects: the groups trade places, a2 a1 stay together")
        store.selectedSessionId = a1
        store.moveTab(a1, onto: b1) // the grid's first session moves to the middle of the tabs
        XCTAssertEqual(store.visibleSessionIds, tabs, "all on screen: the grid is the tabs, never rotated to one of them")
    }

    /// More sessions than panes: the swap happens in place, the window doesn't slide.
    func testSwapInsideAWiderListKeepsTheWindow() throws {
        store.applyPreset(.full) // two panes
        let (a1, _, _) = (try newSession(in: 0), try newSession(in: 0), try newSession(in: 1))
        store.selectedSessionId = a1 // both panes of one project: a swap inside its group
        let before = store.visibleSessionIds
        XCTAssertEqual(before.count, 2)
        store.swapTabs(before[0], before[1])
        XCTAssertEqual(store.visibleSessionIds, [before[1], before[0]], "the window would slide if the anchor stayed")
    }

    /// Panes of two projects: their groups trade places, and the pane that was dragged stays on screen, selected —
    /// not the one selected before, which would push it off.
    func testDraggedPaneOfAnotherProjectStaysOnScreen() throws {
        store.applyPreset(.full) // two panes
        let (a1, a2, b1) = (try newSession(in: 0), try newSession(in: 0), try newSession(in: 1))
        store.selectedSessionId = b1
        XCTAssertEqual(store.visibleSessionIds, [a2, b1])
        store.swapTabs(a2, b1)
        XCTAssertEqual(tabs, [b1, a1, a2])
        XCTAssertEqual(store.selectedSessionId, a2)
        XCTAssertEqual(store.visibleSessionIds, [a1, a2])

        store.selectedSessionId = b1
        XCTAssertEqual(store.visibleSessionIds, [b1, a1])
        store.swapTabs(b1, a1)
        XCTAssertEqual(tabs, [a1, a2, b1])
        XCTAssertEqual(store.visibleSessionIds, [a2, b1], "b1 kept, and a2 rather than nothing new")
    }

    /// More tabs than panes: the last tab shares the grid with the ones before it — never wrapped to the first tab.
    func testLastTabIsShownWithItsNeighboursNotTheFirstTab() throws {
        store.applyPreset(.full) // two panes
        let (a1, b1, b2, b3) = (try newSession(in: 0), try newSession(in: 1), try newSession(in: 1), try newSession(in: 1))
        store.selectedSessionId = a1
        XCTAssertEqual(store.visibleSessionIds, [a1, b1])
        store.selectedSessionId = b3
        XCTAssertEqual(store.visibleSessionIds, [b2, b3], "not [b3, a1]: another project's session wrapped in")
        _ = b1
    }

    /// Opened after a drag: last in its project's group — the other groups keep their order.
    func testNewSessionGoesLastInItsGroup() throws {
        let (a1, b1) = (try newSession(in: 0), try newSession(in: 1))
        store.moveTab(b1, onto: a1) // [b1, a1]
        let b2 = try newSession(in: 1)
        let a2 = try newSession(in: 0)
        XCTAssertEqual(tabs, [b1, b2, a1, a2], "not [b1, a1, b2, a2]: a project's tabs stand together")
    }

    /// A tab never leaves its group: dropped on another project's tab, the whole group moves there.
    func testTabDroppedOnAnotherGroupMovesItsGroup() throws {
        let (a1, a2, b1, b2) = (try newSession(in: 0), try newSession(in: 0), try newSession(in: 1), try newSession(in: 1))
        store.moveTab(b2, onto: a2)
        XCTAssertEqual(tabs, [b1, b2, a1, a2], "a move of the tab alone would give [a1, b2, a2, b1]")
        store.moveTab(a2, onto: a1)
        XCTAssertEqual(tabs, [b1, b2, a2, a1], "inside the group: just that tab moves")
        XCTAssertEqual(store.tabGroups.map(\.kind), [.project(store.projects[1].id!), .project(store.projects[0].id!)])
    }

    /// Two projects' support sessions in one named group: they stand together, the rest stay by project, and it
    /// holds after a restart; back to the project, the session rejoins its project's tabs.
    func testNamedGroupGathersSessionsOfDifferentProjects() throws {
        let (a1, a2, b1, b2) = (try newSession(in: 0), try newSession(in: 0), try newSession(in: 1), try newSession(in: 1))
        store.setGroup(a2, to: " support ")
        store.setGroup(b1, to: "support")
        XCTAssertEqual(tabs, [a1, a2, b1, b2], "a2 starts the group: b1 joins it there, not by project")
        XCTAssertEqual(store.tabGroups.map(\.kind), [.project(store.projects[0].id!), .named("support"), .project(store.projects[1].id!)])
        XCTAssertEqual(store.groupNames, ["support"])

        store.moveTab(b1, onto: a2)
        XCTAssertEqual(tabs, [a1, b1, a2, b2], "inside a named group a tab moves alone")

        store = makeStore()
        XCTAssertEqual(store.tabGroups.map(\.kind), [.project(store.projects[0].id!), .named("support"), .project(store.projects[1].id!)])

        store.setGroup(b1, to: nil)
        store.setGroup(a2, to: "")
        XCTAssertEqual(store.tabGroups.map(\.kind), [.project(store.projects[0].id!), .project(store.projects[1].id!)])
        XCTAssertTrue(store.groupNames.isEmpty)
    }

    /// An order dragged before groups existed, projects mixed: each project gathers where its first tab stood.
    func testMixedOldOrderGathersByFirstTab() throws {
        let (a1, a2, b1) = (try newSession(in: 0), try newSession(in: 0), try newSession(in: 1))
        defaults.set([a1, b1, a2], forKey: "tabOrder")
        store = makeStore()
        XCTAssertEqual(tabs, [a1, a2, b1])
    }

    /// A collapsed group stays collapsed after a restart; its sessions stay in the grid.
    func testCollapsedGroupSurvivesRestart() throws {
        store.applyPreset(.deck)
        let (a1, a2, b1) = (try newSession(in: 0), try newSession(in: 0), try newSession(in: 1))
        let projectA = store.tabGroups[0].key
        store.toggleGroup(projectA)
        store = makeStore()
        XCTAssertEqual(store.collapsedGroups, [projectA])
        XCTAssertEqual(store.visibleSessionIds, [a1, a2, b1], "collapsing hides tabs, not panes")
        store.toggleGroup(projectA)
        XCTAssertTrue(store.collapsedGroups.isEmpty)
    }

    /// Closing a tab and opening a fresh session of that project puts it back in the same place.
    func testFreshSessionTakesTheClosedOnesPlace() throws {
        let (a1, a2, b1) = (try newSession(in: 0), try newSession(in: 0), try newSession(in: 1))
        store.moveTab(a1, onto: a2) // [a2, a1, b1]
        store.closeSession(a2)
        XCTAssertEqual(tabs, [a1, b1])
        let a3 = try newSession(in: 0)
        XCTAssertEqual(tabs, [a3, a1, b1], "back in a2's place, not last")
        store.selectedSessionId = a1
        try store.replaceSession(a1) // New Session Instead
        let fresh = try XCTUnwrap(store.selectedSessionId)
        XCTAssertEqual(tabs, [a3, fresh, b1], "the replacement keeps a1's place")
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
