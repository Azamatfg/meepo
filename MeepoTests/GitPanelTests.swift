import SwiftUI
import XCTest
@testable import Meepo

final class GitPanelParsingTests: XCTestCase {
    func testStatusHeaderAndFiles() {
        let snapshot = GitPanel.parseStatus("""
            ## main...origin/main [ahead 5, behind 1]
             M Meepo/App/AppStore.swift
            A  new.swift
            R  old.swift -> renamed.swift
             D gone.swift
            ?? "with space.md"
            """)
        XCTAssertEqual(snapshot.branch, "main")
        XCTAssertEqual(snapshot.upstream, "origin/main")
        XCTAssertEqual([snapshot.ahead, snapshot.behind], [5, 1])
        XCTAssertEqual(snapshot.changes.map(\.status), ["M", "A", "R", "D", "?"])
        XCTAssertEqual(snapshot.changes.map(\.path), ["Meepo/App/AppStore.swift", "new.swift", "renamed.swift", "gone.swift", "with space.md"])

        let local = GitPanel.parseStatus("## feature\n")
        XCTAssertEqual(local.branch, "feature")
        XCTAssertNil(local.upstream)                                     // PUBLISH, not PUSH
    }

    func testNumstatAndBinaryFiles() {
        let counts = GitPanel.parseNumstat("3\t0\tMeepo/App/AppStore.swift\n-\t-\tassets/icon.png\n")
        XCTAssertEqual(counts["Meepo/App/AppStore.swift"]?.0, 3)
        XCTAssertEqual(counts["assets/icon.png"]?.0, 0)
    }

    func testExplainPromptSpeaksTheUsersLanguageAndListsNewFiles() {
        let prompt = GitPanel.explainPrompt(diff: "-a\n+b", newFiles: ["tests/test_cache.py"], language: "Russian")
        XCTAssertTrue(prompt.contains("In Russian."))
        XCTAssertTrue(prompt.contains("<new_files>\ntests/test_cache.py"))
        XCTAssertTrue(prompt.contains("<diff>\n-a\n+b"))
    }
}

/// Discard Changes as in VS Code, against a real repo; the Trash is a stand-in folder, never the user's.
final class GitPanelDiscardTests: XCTestCase {
    private var trashed: [String] = []

    private func discard(_ files: [String]?, in repo: URL) -> String? {
        let changes = GitPanel.sourceControl(in: repo.path).changes                      // what the panel lists
        let bin = FileManager.default.temporaryDirectory.appending(path: "trash-\(UUID().uuidString)")
        return GitPanel.discard(changes.filter { files?.contains($0.path) ?? true }, in: repo.path) { url in
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: bin.appending(path: UUID().uuidString))
            self.trashed.append(url.lastPathComponent)
        }
    }

    private func read(_ file: String, in repo: URL) -> String? { try? String(contentsOf: repo.appending(path: file), encoding: .utf8) }
    private func write(_ text: String, _ file: String, in repo: URL) throws {
        try text.write(to: repo.appending(path: file), atomically: true, encoding: .utf8)
    }

    private func repoWithCommit() throws -> URL {
        let repo = try makeTempRepo()
        for name in ["a.txt", "b.txt", "gone.txt", "old.txt", "x[1].txt", "x1.txt"] { try write("v1 \(name)", name, in: repo) }
        try git(["add", "."], in: repo)
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "base"], in: repo)
        return repo
    }

    func testOneFileAtATimeLeavesTheOthersAlone() throws {
        let repo = try repoWithCommit()
        try write("edited", "a.txt", in: repo)
        try write("edited too", "b.txt", in: repo)
        try git(["add", "b.txt"], in: repo)                                  // staged edits are discarded too
        try write("new", "park_transactions (2).csv", in: repo)
        try write("edited", "x[1].txt", in: repo)
        try write("edited", "x1.txt", in: repo)

        XCTAssertNil(discard(["a.txt", "b.txt"], in: repo))
        XCTAssertEqual(read("a.txt", in: repo), "v1 a.txt")
        XCTAssertEqual(read("b.txt", in: repo), "v1 b.txt")
        XCTAssertEqual(read("park_transactions (2).csv", in: repo), "new")   // not asked for: untouched
        XCTAssertTrue(trashed.isEmpty)

        XCTAssertNil(discard(["park_transactions (2).csv"], in: repo))
        XCTAssertNil(read("park_transactions (2).csv", in: repo))
        XCTAssertEqual(trashed, ["park_transactions (2).csv"])               // to the Trash, not deleted

        XCTAssertNil(discard(["x[1].txt"], in: repo))
        XCTAssertEqual(read("x[1].txt", in: repo), "v1 x[1].txt")
        XCTAssertEqual(read("x1.txt", in: repo), "edited")                  // "x[1].txt" is a name, not a glob
    }

    func testAddedDeletedRenamedAndDiscardAll() throws {
        let repo = try repoWithCommit()
        try write("staged new", "added.txt", in: repo)
        try git(["add", "added.txt"], in: repo)
        try write("then edited", "added.txt", in: repo)                      // AM: index differs from disk
        try FileManager.default.removeItem(at: repo.appending(path: "gone.txt"))
        try git(["mv", "old.txt", "renamed.txt"], in: repo)
        try write("edited", "a.txt", in: repo)

        XCTAssertNil(discard(nil, in: repo))
        XCTAssertNil(GitService.output(["status", "--porcelain"], in: repo.path))   // clean, like HEAD
        XCTAssertEqual(read("gone.txt", in: repo), "v1 gone.txt")
        XCTAssertEqual(read("old.txt", in: repo), "v1 old.txt")
        XCTAssertEqual(read("a.txt", in: repo), "v1 a.txt")
        XCTAssertEqual(read("b.txt", in: repo), "v1 b.txt")
        XCTAssertEqual(Set(trashed), ["added.txt", "renamed.txt"])
    }

    func testRenameKeepsItsOldPath() {
        let change = GitPanel.parseStatus("R  old.swift -> renamed.swift\n").changes[0]
        XCTAssertEqual([change.path, change.oldPath], ["renamed.swift", "old.swift"])
    }
}

/// Against a real bare remote: ahead/behind, outgoing commits, PUSH and PULL.
final class GitPanelRemoteTests: XCTestCase {
    func testAheadOutgoingPushAndPull() throws {
        let remote = FileManager.default.temporaryDirectory.appending(path: "remote-\(UUID().uuidString).git")
        try git(["init", "-q", "--bare", "-b", "main", remote.path], in: FileManager.default.temporaryDirectory)
        let repo = try makeTempRepo()
        try git(["checkout", "-q", "-B", "main"], in: repo)
        try git(["commit", "-q", "--allow-empty", "-m", "base"], in: repo)
        try git(["remote", "add", "origin", remote.path], in: repo)

        var snapshot = GitPanel.snapshot(in: repo.path)
        XCTAssertNil(snapshot.upstream)
        XCTAssertNil(GitPanel.push(snapshot, in: repo.path))              // PUBLISH sets the upstream

        try git(["commit", "-q", "--allow-empty", "-m", "local work"], in: repo)
        try "x".write(to: repo.appending(path: "draft.txt"), atomically: true, encoding: .utf8)
        snapshot = GitPanel.snapshot(in: repo.path)
        XCTAssertEqual(snapshot.upstream, "origin/main")
        XCTAssertEqual(snapshot.ahead, 1)
        XCTAssertEqual(snapshot.changes.map(\.status), ["?"])
        let scm = GitPanel.sourceControl(in: repo.path)
        XCTAssertEqual(scm.outgoing.commits.map(\.subject), ["local work"])  // what PUSH would send
        XCTAssertEqual(GitPanel.versions(of: scm.changes[0], old: "HEAD", new: nil, in: repo.path).new, Data("x".utf8))

        XCTAssertNil(GitPanel.push(snapshot, in: repo.path))
        XCTAssertEqual(GitPanel.snapshot(in: repo.path).ahead, 0)

        // Someone else pushes; PULL fast-forwards.
        let other = FileManager.default.temporaryDirectory.appending(path: "clone-\(UUID().uuidString)")
        try git(["clone", "-q", remote.path, other.path], in: FileManager.default.temporaryDirectory)
        try git(["-c", "user.email=o@o", "-c", "user.name=o", "commit", "-q", "--allow-empty", "-m", "theirs"], in: other)
        try git(["push", "-q"], in: other)
        GitPanel.fetch(in: repo.path)
        XCTAssertEqual(GitPanel.snapshot(in: repo.path).behind, 1)
        XCTAssertNil(GitPanel.pull(in: repo.path))
        XCTAssertEqual(GitPanel.snapshot(in: repo.path).behind, 0)
    }
}

/// Non-ASCII names come out of git as they are, not as "\320\272…" (core.quotePath=false, as Claude Code runs git).
final class NonASCIIPathTests: XCTestCase {
    func testCyrillicFilesReadCompareAndColor() throws {
        let repo = try makeTempRepo()
        let folder = repo.appending(path: "папка")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "один\n".write(to: folder.appending(path: "контент.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        try git(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-qm", "init"], in: repo)
        try "один\nдва\n".write(to: folder.appending(path: "контент.txt"), atomically: true, encoding: .utf8)
        try "новый\n".write(to: repo.appending(path: "отчёт.md"), atomically: true, encoding: .utf8)

        let changes = GitPanel.sourceControl(in: repo.path).changes
        XCTAssertEqual(changes.map(\.path).sorted(), ["отчёт.md", "папка/контент.txt"])
        let edited = try XCTUnwrap(changes.first { $0.path == "папка/контент.txt" })
        XCTAssertEqual(edited.added, 1, "+/− are found by the same name")
        let versions = GitPanel.versions(of: edited, old: "HEAD", new: nil, in: repo.path)
        XCTAssertEqual(versions.old, Data("один\n".utf8), "Compare gets the committed side")
        XCTAssertEqual(versions.new, Data("один\nдва\n".utf8))
        let entry = try XCTUnwrap(FileTree.list("папка", in: repo.path).first)
        XCTAssertEqual(FileTree.status(of: entry, changes: changes), "M", "Explorer colors it")
    }
}

/// Measured the way a popover measures (proposing nothing): a (420, ∞) proposal would hide the empty file list.
@MainActor
final class CommitLayoutTests: XCTestCase {
    private func height(body lines: Int, files: Int, web: URL? = nil) -> CGFloat {
        let body = (0..<lines).map { "Line \($0) of the body" }.joined(separator: "\n")
        let detail = GitPanel.CommitDetail(
            sha: String(repeating: "8cc4cd24", count: 5), author: "Tester", date: "Sat, 27 Sep 2026 11:53:00 +0500",
            message: "feat: import the schedule from Excel" + (body.isEmpty ? "" : "\n\n" + body), parent: GitPanel.emptyTree,
            files: (0..<files).map { GitPanel.FileChange(status: "M", path: "src/module\($0)/file\($0).swift", added: 3, removed: 1) })
        return NSHostingController(rootView: CommitCardContent(detail: detail, web: web) { _ in }).sizeThatFits(in: .zero).height
    }

    func testFilesAndBodyShowAndAHugeCommitStillFits() {
        let bare = height(body: 0, files: 0)
        XCTAssertGreaterThanOrEqual(height(body: 0, files: 15) - bare, 130, "15 files are listed")
        XCTAssertGreaterThanOrEqual(height(body: 10, files: 0) - bare, 100, "a 10-line body shows")
        XCTAssertLessThanOrEqual(height(body: 200, files: 400), 480, "the message and the list scroll inside the card")
    }

    /// Hash, Copy hash, Compare and the web link share one line; with a 12-character hash it wrapped (8pt taller).
    func testFooterStaysOneLine() {
        let plain = height(body: 0, files: 1)
        XCTAssertEqual(height(body: 0, files: 1, web: URL(string: "https://github.com/o/r/commit/8cc4cd24")), plain)
        XCTAssertEqual(height(body: 0, files: 1, web: URL(string: "https://gitlab.com/o/r/-/commit/8cc4cd24")), plain)
    }

    func testLongAuthorDoesNotWidenTheColumn() {
        let row = CommitRow(commit: GitPanel.CommitLine(sha: "8cc4cd2", author: "Santiago Fernández de Valderrama Aparicio",
                                                        subject: "fix: loans import", when: "2 hours ago"))
        XCTAssertLessThanOrEqual(NSHostingController(rootView: row).sizeThatFits(in: CGSize(width: 232, height: 100)).width, 232)
    }
}
