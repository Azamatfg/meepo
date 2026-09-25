import GRDB
import XCTest
@testable import Meepo

/// Import reads Claude Code's own records, so it finds work done from any editor or terminal (2026-09-24).
final class ClaudeImportTests: XCTestCase {
    private let tmp = FileManager.default.temporaryDirectory.appending(path: "ci-\(UUID().uuidString)")

    private func write(_ text: String, to url: URL, age: TimeInterval = 0) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    private func transcript(cwd: String, id: String, age: TimeInterval, title: String? = nil) throws {
        var lines = [#"{"type":"summary"}"#, #"{"type":"user","cwd":"\#(cwd)","message":{"content":"hi"}}"#]
        if let title { lines.append(#"{"type":"ai-title","aiTitle":"\#(title)"}"#) }
        try write(lines.joined(separator: "\n"), to: tmp.appending(path: ".claude/projects/\(ClaudeImport.claudeFolderName(for: cwd))/\(id).jsonl"), age: age)
    }

    func testFoldersFromClaudeCodeHistory() throws {
        let terminalRepo = try makeTempRepo()                      // used from a terminal: no IDE ever saw it
        let sub = terminalRepo.appending(path: "backend")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let notes = tmp.appending(path: "notes")                   // no git
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let added = try makeTempRepo()
        let home = tmp.appending(path: "home").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)

        try transcript(cwd: terminalRepo.path, id: "s-root", age: 60, title: "Refactor billing")
        try transcript(cwd: sub.path, id: "s-sub", age: 30)
        try transcript(cwd: notes.path, id: "s-notes", age: 3_600)
        try transcript(cwd: terminalRepo.path + "/.claude/worktrees/feat", id: "s-wt", age: 10)
        let config = tmp.appending(path: ".claude.json")
        try write(#"{"projects":{"\#(added.path)":{},"\#(home)":{},"/nowhere/gone":{},"/private/tmp/scratch":{}}}"#, to: config)

        let folders = ClaudeImport.folders(claudeHome: tmp.appending(path: ".claude"), config: config,
                                           skip: [added.path], home: home, scratch: ["/private/tmp/"])  // tests live in /private/var
        guard folders.count == 2 else { return XCTFail("\(folders.map(\.path))") }
        XCTAssertEqual(folders.map(\.path), [terminalRepo.path, notes.path])   // newest first; sub → its repo
        XCTAssertEqual(folders.map(\.isGit), [true, false])
        XCTAssertEqual(folders[0].session?.title, "Refactor billing")          // only a root conversation resumes
        XCTAssertEqual(folders[0].session?.id, "s-root")
        XCTAssertNotNil(folders[0].lastUsed)
    }

    /// Real names from ~/.claude/projects (2026-09-24).
    func testClaudeFolderNamesMatchClaudeCode() {
        XCTAssertEqual(ClaudeImport.claudeFolderName(for: "/Users/Azamat/.meepo"), "-Users-Azamat--meepo")
        XCTAssertEqual(ClaudeImport.claudeFolderName(for: "/Users/Azamat/Desktop/taxi kolesa project/backend/taxi-kolesa"),
                       "-Users-Azamat-Desktop-taxi-kolesa-project-backend-taxi-kolesa")
        XCTAssertEqual(ClaudeImport.claudeFolderName(for: "/Users/Azamat/Проект"), "-Users-Azamat-------")
    }
}

/// A folder without git is a project too (user decision 2026-09-24).
@MainActor
final class PlainFolderProjectTests: XCTestCase {
    func testPlainFolderAddsAndRunsSessionsWithoutGitParts() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        let folder = FileManager.default.temporaryDirectory.appending(path: "plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try store.addProject(at: folder)
        XCTAssertEqual(store.projects.map(\.path), [folder.standardizedFileURL.path])
        XCTAssertNil(store.projects[0].remote)
        try store.createSession(projectId: store.projects[0].id!, model: nil, prompt: nil)
        XCTAssertNil(store.sessions[0].branch)
        XCTAssertFalse(GitPanel.sourceControl(in: folder.path).isRepository)   // inspector offers git init
    }
}
