@testable import Meepo
import XCTest

final class EditorTests: XCTestCase {
    private var dir: URL!
    private var backups: URL { dir.appending(path: "backups") }
    private var file: URL { dir.appending(path: "a.swift") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "let a = 1\n".write(to: file, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testSaveWritesAndKeepsABackupThatUndoes() throws {
        XCTAssertEqual(try Editor.write("let a = 2\n", to: file.path, expecting: "let a = 1\n", backups: backups), .saved)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let a = 2\n")
        let entry = try XCTUnwrap(ChangeLog.entries(backups: backups).first)
        XCTAssertEqual(entry.action, "Edit a.swift")
        try ChangeLog.restore(entry, backups: backups)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let a = 1\n", "undo in Changes brings the old text back")
    }

    func testAFileChangedOnDiskIsNotWrittenOver() throws {
        try "let a = 99\n".write(to: file, atomically: true, encoding: .utf8) // Claude edited it after it was opened
        XCTAssertEqual(try Editor.write("let a = 2\n", to: file.path, expecting: "let a = 1\n", backups: backups),
                       .changedOnDisk("let a = 99\n"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let a = 99\n")
        XCTAssertEqual(try Editor.write("let a = 2\n", to: file.path, expecting: nil, backups: backups), .saved, "Overwrite")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let a = 2\n")
    }

    func testSavingTheSameTextTouchesNothing() throws {
        XCTAssertEqual(try Editor.write("let a = 1\n", to: file.path, expecting: "let a = 1\n", backups: backups), .saved)
        XCTAssertTrue(ChangeLog.entries(backups: backups).isEmpty)
    }

    func testBinaryAndHugeFilesDontOpen() throws {
        let binary = dir.appending(path: "b.bin")
        try Data([0, 1, 2, 0, 255]).write(to: binary)
        XCTAssertThrowsError(try Editor.read(binary.path).get())
        XCTAssertEqual(try Editor.read(file.path).get(), "let a = 1\n")
    }
}
