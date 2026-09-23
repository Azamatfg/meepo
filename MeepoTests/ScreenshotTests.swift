import XCTest
@testable import Meepo

@MainActor
final class ScreenshotTests: XCTestCase {
    func testOnlyShotsOlderThanAnHourAreRemoved() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appending(path: "old.png"), fresh = dir.appending(path: "fresh.png")
        for file in [old, fresh] { try Data([1]).write(to: file) }
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-2 * 3600)], ofItemAtPath: old.path)
        ScreenshotFlow.removeOldShots(in: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path)) // may still be in the picker
    }

    func testHotKeyChoicesAreDistinct() {
        let combos = GlobalHotKey.combos.map { "\($0.keyCode)-\($0.modifiers)" }
        XCTAssertEqual(Set(combos).count, combos.count)
        XCTAssertEqual(GlobalHotKey.combos.first?.title, "⌘⇧6") // the default in AppStore
    }
}
