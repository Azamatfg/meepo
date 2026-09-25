import GRDB
import XCTest
@testable import Meepo

/// SPEC §8: every change to the user's files is logged and can be undone.
final class ChangeLogTests: XCTestCase {
    private let tmp = FileManager.default.temporaryDirectory.appending(path: "cl-\(UUID().uuidString)")
    private var backups: URL { tmp.appending(path: "backups") }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func testRestoringPutsTheOldFileBackAndCanItselfBeUndone() throws {
        let file = tmp.appending(path: "settings.json")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try "mine".write(to: file, atomically: true, encoding: .utf8)
        let backup = try ChangeLog.backup(file, folder: "t", backups: backups)
        try "meepo's".write(to: file, atomically: true, encoding: .utf8)
        ChangeLog.record("Hook bridge", file: file, backup: backup, backups: backups)

        let change = try XCTUnwrap(ChangeLog.entries(backups: backups).first)
        try ChangeLog.restore(change, backups: backups)
        XCTAssertEqual(try read(file), "mine")

        let undo = try XCTUnwrap(ChangeLog.entries(backups: backups).first)   // newest first
        XCTAssertEqual(undo.action, "Restore: Hook bridge")
        try ChangeLog.restore(undo, backups: backups)
        XCTAssertEqual(try read(file), "meepo's")
    }

    func testAFileMeepoCreatedIsRemovedOnRestore() throws {
        let file = tmp.appending(path: "commands/ship.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "copied".write(to: file, atomically: true, encoding: .utf8)
        ChangeLog.record("Copy /ship", file: file, backup: nil, backups: backups)
        try ChangeLog.restore(try XCTUnwrap(ChangeLog.entries(backups: backups).first), backups: backups)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// Each place that touches user files leaves a log line: bridge, notification guard, git exclude.
    func testWriteSitesAreLogged() throws {
        let home = tmp.appending(path: "home")
        let bridge = BridgeInstaller(settingsURL: home.appending(path: "settings.json"), meepoHome: home)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try #"{"hooks":{"Notification":[{"hooks":[{"type":"command","command":"n.sh"}]}]}}"#
            .write(to: bridge.settingsURL, atomically: true, encoding: .utf8)
        try bridge.install()
        try bridge.setNotifyGuard(true, projectPaths: [])
        let repo = try makeTempRepo()
        try git(["config", "core.excludesFile", "/dev/null"], in: repo)   // the user's global excludes may already ignore it
        GitService.ensureWorktreesIgnored(in: repo.path, backups: home.appending(path: "backups"))

        let actions = ChangeLog.entries(backups: home.appending(path: "backups")).map(\.action)
        XCTAssertTrue(actions.contains("Hook bridge"))
        XCTAssertTrue(actions.contains("Quiet own Notification hooks in meepo"))
        XCTAssertTrue(actions.contains("Ignore .claude/worktrees"))
    }
}
