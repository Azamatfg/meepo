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
