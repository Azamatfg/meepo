import GRDB
import XCTest
@testable import Meepo

final class ShellLayoutTests: XCTestCase {
    func testPresetsNeverShowAPanelTwice() {
        for preset in ShellLayout.Preset.allCases {
            guard let layout = ShellLayout.preset(preset) else { continue }
            let all = layout.left + layout.right + layout.bottom
            XCTAssertEqual(all.count, Set(all).count, "\(preset)")
            XCTAssertTrue(ShellLayout.splits.contains(layout.split), "\(preset)")
        }
    }

    func testMovingTakesThePanelOutOfItsOldZone() {
        var layout = ShellLayout.preset(.focus)!
        layout.move(.product, to: .left)
        XCTAssertEqual(layout.left, [.product])
        XCTAssertEqual(layout.right, [.waiting])
        XCTAssertEqual(layout.zone(of: .product), .left)
    }

    func testTogglingHidesAShownPanelAndOpensAHiddenOneOnTheLeft() {
        var layout = ShellLayout.preset(.focus)!
        layout.toggle(.waiting)
        XCTAssertNil(layout.zone(of: .waiting))
        layout.toggle(.explorer)
        XCTAssertEqual(layout.left.first, .explorer)
    }

    func testSurvivesSaving() throws {
        let layout = ShellLayout.preset(.full)!
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

    func testAnEditByHandBecomesCustomAndComesBack() {
        store.applyPreset(.focus)
        store.editShell { $0.move(.ci, to: .bottom) }
        XCTAssertEqual(store.shellPreset, .custom)
        store.applyPreset(.deck)
        XCTAssertEqual(store.shell, ShellLayout.preset(.deck))
        store.applyPreset(.custom)
        XCTAssertEqual(store.shell.bottom, [.ci], "Custom is the arrangement made by hand, not the last preset")
    }

    func testANoOpEditKeepsThePreset() {
        store.applyPreset(.full)
        store.editShell { $0.split = 2 }
        XCTAssertEqual(store.shellPreset, .full)
    }

    func testTheLayoutOutlivesARestart() throws {
        store.applyPreset(.full)
        store.editShell { $0.split = 4 }
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "shell-\(UUID().uuidString)")
        let again = AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "s.json"), meepoHome: tmp),
                             usageRoot: tmp, defaults: defaults)
        XCTAssertEqual(again.shellPreset, .custom)
        XCTAssertEqual(again.shell.split, 4)
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
        XCTAssertEqual(store.visibleSessionIds, [ids[1], ids[0]], "The selected one first, then the others in order")
        store.isHomeShown = true
        XCTAssertEqual(store.visibleSessionIds, [], "Home shows no terminal, so notifications still come")
        store.selectedSessionId = ids[2]
        XCTAssertFalse(store.isHomeShown, "Picking a session leaves Home")
    }
}
