import GRDB
import XCTest
@testable import Meepo

final class ShellLayoutTests: XCTestCase {
    func testPresetsNeverShowAPanelTwice() {
        for preset in ShellLayout.Preset.allCases {
            let layout = ShellLayout.preset(preset)
            let all = layout.left + layout.right + layout.bottom
            XCTAssertEqual(all.count, Set(all).count, "\(preset)")
            XCTAssertTrue(ShellLayout.splits.contains(layout.split), "\(preset)")
        }
    }

    func testMovingTakesThePanelOutOfItsOldZone() {
        var layout = ShellLayout.preset(.focus)
        layout.move(.product, to: .left)
        XCTAssertEqual(layout.left, [.product])
        XCTAssertEqual(layout.right, [.waiting])
        XCTAssertEqual(layout.zone(of: .product), .left)
    }

    func testTogglingHidesAShownPanelAndOpensAHiddenOneOnTheLeft() {
        var layout = ShellLayout.preset(.focus)
        layout.toggle(.waiting)
        XCTAssertNil(layout.zone(of: .waiting))
        layout.toggle(.explorer)
        XCTAssertEqual(layout.left.first, .explorer)
    }

    func testSurvivesSaving() throws {
        let layout = ShellLayout.preset(.full)
        XCTAssertEqual(try JSONDecoder().decode(ShellLayout.self, from: JSONEncoder().encode(layout)), layout)
    }
}

@MainActor
final class ShellStoreTests: XCTestCase {
    private var store: AppStore!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "shell-\(UUID().uuidString)")
        defaults = UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!
        store = AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "s.json"), meepoHome: tmp),
                         usageRoot: tmp, defaults: defaults)
    }

    func testEachPresetKeepsItsOwnChanges() {
        store.applyPreset(.focus)
        store.editShell { $0.move(.ci, to: .bottom) }
        XCTAssertEqual(store.shellPreset, .focus, "changing Focus keeps you in Focus")
        store.applyPreset(.deck)
        XCTAssertEqual(store.shell, ShellLayout.preset(.deck), "other presets aren't touched")
        store.applyPreset(.focus)
        XCTAssertEqual(store.shell.bottom, [.ci], "Focus comes back as you set it")
        store.resetPreset(.focus)
        XCTAssertEqual(store.shell, ShellLayout.preset(.focus))
        XCTAssertNil(store.editedLayouts[.focus])
    }

    func testChangingBackToTheDefaultIsNotAnEdit() {
        store.applyPreset(.full)
        store.editShell { $0.split = 4 }
        store.editShell { $0.split = 2 }
        XCTAssertNil(store.editedLayouts[.full])
    }

    func testTheLayoutOutlivesARestart() throws {
        store.applyPreset(.full)
        store.editShell { $0.split = 4 }
        store.applyPreset(.focus)
        let again = try restarted()
        again.applyPreset(.full)
        XCTAssertEqual(again.shell.split, 4)
    }

    func testAnOldCustomLayoutBecomesFulls() throws {
        let custom = ShellLayout(left: [.sessions, .explorer], right: [.ci], bottom: [], split: 2)
        defaults.set(try JSONEncoder().encode(custom), forKey: "shellCustom")
        defaults.set("custom", forKey: "shellPreset")
        let again = try restarted()
        XCTAssertEqual(again.shellPreset, .full)
        XCTAssertEqual(again.editedLayouts[.full], custom)
        XCTAssertNil(defaults.object(forKey: "shellCustom"))
    }

    func testAnUnknownPresetDoesntLoseTheOthers() throws {
        let full = ShellLayout(left: [.explorer], right: [], bottom: [], split: 2)
        defaults.set(try JSONEncoder().encode(["full": full, "someday": full]), forKey: "shellEdited")
        XCTAssertEqual(try restarted().editedLayouts[.full], full)
    }

    private func restarted() throws -> AppStore {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "shell-\(UUID().uuidString)")
        return AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "s.json"), meepoHome: tmp),
                        usageRoot: tmp, defaults: defaults)
    }

    func testAHiddenStageComesBackInItsPlace() {
        let without = Stage.defaults.filter { $0.name != "qa" && $0.name != "sync" }
        let stage = { name in Stage.defaults.first { $0.name == name }! }
        XCTAssertEqual(Stage.adding(stage("qa"), to: without).map(\.name),
                       ["spec", "plan", "code", "qa", "security", "simplify", "review", "ship"])
        XCTAssertEqual(Stage.adding(stage("sync"), to: without).map(\.name).last, "sync")
    }

    func testOnlyTerminalsOnScreenCountAsSeen() throws {
        let repo = try makeTempRepo()
        try store.addProject(at: repo)
        let project = store.projects[0].id!
        for _ in 0..<3 { try store.createSession(projectId: project, model: nil, prompt: nil) }
        let ids = store.orderedSessions.compactMap(\.id)
        store.selectedSessionId = ids[1]
        store.applyPreset(.focus)
        XCTAssertEqual(store.visibleSessionIds, [ids[1]])
        store.applyPreset(.full)
        XCTAssertEqual(store.visibleSessionIds, [ids[1], ids[2]], "from the selected one on, in the sidebar's order")
        store.selectedSessionId = ids[2]
        XCTAssertEqual(store.visibleSessionIds, [ids[1], ids[2]], "clicking the other terminal focuses it; nothing moves")
        store.selectedSessionId = ids[0]
        XCTAssertEqual(store.visibleSessionIds, [ids[0], ids[1]], "a session not on screen brings its own row")
        store.isHomeShown = true
        XCTAssertEqual(store.visibleSessionIds, [], "Home shows no terminal, so notifications still come")
        store.selectedSessionId = ids[2]
        XCTAssertFalse(store.isHomeShown, "Picking a session leaves Home")
    }
}
