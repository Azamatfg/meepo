import XCTest
@testable import Meepo

final class IDEImportTests: XCTestCase {
    private let tmp = FileManager.default.temporaryDirectory.appending(path: "ide-\(UUID().uuidString)")

    private func write(_ text: String, to path: String) throws {
        let url = tmp.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func workspace(_ ide: String, _ hash: String, folder: URL, age: TimeInterval) throws {
        try write(#"{"folder":"\#(folder.absoluteString)"}"#, to: "\(ide)/User/workspaceStorage/\(hash)/workspace.json")
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-age)],
                                              ofItemAtPath: tmp.appending(path: "\(ide)/User/workspaceStorage/\(hash)").path)
    }

    /// Only git repos, deduplicated across IDEs by repo root, open windows first, then most recent.
    func testRecentGitFoldersAcrossIDEsOpenWindowsFirst() throws {
        let old = try makeTempRepo(), recent = try makeTempRepo(), open = try makeTempRepo(), added = try makeTempRepo()
        let sub = recent.appending(path: "backend")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let plain = tmp.appending(path: "not-a-repo")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        try workspace("Code", "a", folder: old, age: 9_000)
        try workspace("Code", "b", folder: sub, age: 100)        // a subfolder counts as its repo
        try workspace("Cursor", "c", folder: recent, age: 50)
        try workspace("Code", "d", folder: open, age: 50_000)
        try workspace("Code", "e", folder: plain, age: 10)
        try workspace("Windsurf", "f", folder: added, age: 10)
        try write(#"{"windowsState":{"lastActiveWindow":{"folder":"\#(open.absoluteString)"},"openedWindows":[]}}"#,
                  to: "Code/User/globalStorage/storage.json")

        let folders = IDEImport.recentFolders(support: tmp, skip: [added.path])
        XCTAssertEqual(folders.map(\.path), [open.path, recent.path, old.path])
        XCTAssertEqual(folders.map(\.isOpen), [true, false, false])
        XCTAssertEqual(Set(folders[1].ides), ["VS Code", "Cursor"])
    }

    /// Real names from ~/.claude/projects (2026-09-24).
    func testClaudeFolderNamesMatchClaudeCode() {
        XCTAssertEqual(IDEImport.claudeFolderName(for: "/Users/Azamat/.meepo"), "-Users-Azamat--meepo")
        XCTAssertEqual(IDEImport.claudeFolderName(for: "/Users/Azamat/Desktop/taxi kolesa project/backend/taxi-kolesa"),
                       "-Users-Azamat-Desktop-taxi-kolesa-project-backend-taxi-kolesa")
        XCTAssertEqual(IDEImport.claudeFolderName(for: "/Users/Azamat/Проект"), "-Users-Azamat-------")
    }

    func testLatestSessionTitleFromTheTranscriptTail() throws {
        let folder = "projects/\(IDEImport.claudeFolderName(for: "/work/app"))"
        try write(#"{"type":"ai-title","aiTitle":"Old one"}"#, to: "\(folder)/11111111-old.jsonl")
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-600)],
                                              ofItemAtPath: tmp.appending(path: "\(folder)/11111111-old.jsonl").path)
        try write("""
            {"type":"last-prompt","lastPrompt":"что тут о чем проект"}
            {"type":"ai-title","aiTitle":"Обзор проекта"}
            {"type":"last-prompt","lastPrompt":"что можно взять прямо сейчас"}
            """, to: "\(folder)/22222222-new.jsonl")
        let session = try XCTUnwrap(IDEImport.latestClaudeSession(for: "/work/app", claudeHome: tmp))
        XCTAssertEqual(session.id, "22222222-new")
        XCTAssertEqual(session.title, "Обзор проекта")                 // a title beats a later prompt
        XCTAssertNil(IDEImport.latestClaudeSession(for: "/work/other", claudeHome: tmp))
    }
}

final class UpdateCheckTests: XCTestCase {
    func testVersionsCompareByNumberNotText() {
        XCTAssertTrue(UpdateCheck.isNewer("0.10.0", than: "0.9.3"))   // text order would say no
        XCTAssertTrue(UpdateCheck.isNewer("1.0", than: "0.9.9"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1.0", than: "0.1"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1.0", than: "0.2.0"))
        XCTAssertEqual(UpdateCheck.Release(tag_name: "v0.2.0", html_url: "u").version, "0.2.0")
    }
}
