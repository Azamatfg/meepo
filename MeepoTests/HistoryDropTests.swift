import SwiftUI
import XCTest
@testable import Meepo

final class HistoryTests: XCTestCase {
    func testWebURLFromEitherRemoteForm() {
        let sha = "d486833abc"
        XCTAssertEqual(GitPanel.webURL(remote: "git@github.com:Azamatfg/meepo.git", commit: sha)?.absoluteString,
                       "https://github.com/Azamatfg/meepo/commit/d486833abc")
        XCTAssertEqual(GitPanel.webURL(remote: "https://github.com/Azamatfg/meepo", commit: sha)?.absoluteString,
                       "https://github.com/Azamatfg/meepo/commit/d486833abc")
        XCTAssertEqual(GitPanel.webURL(remote: "ssh://git@gitlab.com/team/app.git", commit: sha)?.absoluteString,
                       "https://gitlab.com/team/app/-/commit/d486833abc")
        XCTAssertNil(GitPanel.webURL(remote: "/Users/me/bare.git", commit: sha), "a local remote has no web page")
        XCTAssertNil(GitPanel.webURL(remote: nil, commit: sha))
        XCTAssertEqual(GitPanel.webURL(remote: "https://me:ghp_SECRET@github.com/o/r.git", commit: sha)?.absoluteString,
                       "https://github.com/o/r/commit/d486833abc", "a token in the remote never reaches the browser")
        XCTAssertEqual(GitPanel.webURL(remote: "ssh://git@github.com:22/o/r/", commit: sha)?.absoluteString,
                       "https://github.com/o/r/commit/d486833abc")
    }

    func testHistoryAndCommitDetail() throws {
        let repo = try makeTempRepo()
        try "one\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        try git(["-c", "user.name=Tester", "-c", "user.email=t@t", "commit", "-qm", "first"], in: repo)
        try "one\ntwo\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: repo.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        try git(["-c", "user.name=Tester", "-c", "user.email=t@t", "commit", "-qm", "second\n\nwith a body"], in: repo)

        let history = GitPanel.sourceControl(in: repo.path).history
        XCTAssertEqual(history.map(\.subject), ["second", "first"], "newest first")
        XCTAssertEqual(history[0].author, "Tester")

        let second = try XCTUnwrap(GitPanel.detail(of: history[0].sha, in: repo.path))
        XCTAssertEqual(second.message, "second\n\nwith a body")
        XCTAssertEqual(second.files.map(\.path).sorted(), ["a.txt", "b.txt"])
        XCTAssertEqual(second.files.first { $0.path == "a.txt" }?.added, 1)
        XCTAssertTrue(second.sha.hasPrefix(history[0].sha))

        let first = try XCTUnwrap(GitPanel.detail(of: history[1].sha, in: repo.path))
        XCTAssertEqual(first.parent, GitPanel.emptyTree, "a first commit is compared with nothing")
        XCTAssertEqual(first.files.map(\.path), ["a.txt"])
    }

    func testEmptyRepoHasNoHistory() throws {
        XCTAssertEqual(GitPanel.sourceControl(in: try makeTempRepo().path).history, [])
    }
}

final class DropTests: XCTestCase {
    func testPathsAreEscapedLikeTerminal() {
        XCTAssertEqual(Drops.escapedPath("/tmp/Screenshot 2026-09-27 at 11.01.11.png"), #"/tmp/Screenshot\ 2026-09-27\ at\ 11.01.11.png"#)
        XCTAssertEqual(Drops.escapedPath("/a/it's (1).txt"), #"/a/it\'s\ \(1\).txt"#)
    }

    func testImagesByExtension() {
        XCTAssertTrue(Drops.isImage(URL(filePath: "/x/shot.png")))
        XCTAssertTrue(Drops.isImage(URL(filePath: "/x/photo.JPG")))
        XCTAssertFalse(Drops.isImage(URL(filePath: "/x/notes.md")))
    }

    func testCopyNeverOverwrites() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "drops-\(UUID().uuidString)")
        let source = tmp.appending(path: "src"), target = tmp.appending(path: "project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "new".write(to: source.appending(path: "logo.png"), atomically: true, encoding: .utf8)
        try "old".write(to: target.appending(path: "logo.png"), atomically: true, encoding: .utf8)

        let copies = try Drops.copy([source.appending(path: "logo.png")], into: target)
        XCTAssertEqual(copies.map(\.lastPathComponent), ["logo 2.png"])
        XCTAssertEqual(try String(contentsOf: target.appending(path: "logo.png"), encoding: .utf8), "old", "the file there stays")
        XCTAssertEqual(try Drops.copy([source.appending(path: "logo.png")], into: target).map(\.lastPathComponent), ["logo 3.png"])
    }

    /// Copying a folder into itself used to nest it ~190 levels deep.
    func testAFolderNeverGoesIntoItself() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "drops-\(UUID().uuidString)")
        let docs = tmp.appending(path: "docs"), inner = docs.appending(path: "inner"), sibling = tmp.appending(path: "docs-old")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "x".write(to: tmp.appending(path: "a.md"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try Drops.copy([tmp.appending(path: "a.md"), docs], into: inner))
        XCTAssertThrowsError(try Drops.copy([docs], into: docs))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inner.path), [], "nothing is copied, not even a.md")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: docs.path), ["inner"])

        XCTAssertEqual(try Drops.copy([docs], into: tmp).map(\.lastPathComponent), ["docs 2"], "next to itself is fine")
        XCTAssertEqual(try Drops.copy([docs], into: sibling).map(\.lastPathComponent), ["docs"], "a name that only starts the same")
    }

    /// The 3rd of 5 fails: the first two were copied and each was reported as it landed (Tools → Changes logs
    /// them); the error says how far it got.
    func testACopyThatFailsHalfwayKeepsWhatItCopied() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "drops-\(UUID().uuidString)")
        let source = tmp.appending(path: "src"), target = tmp.appending(path: "project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for name in ["a.md", "b.md", "d.md", "e.md"] { try "x".write(to: source.appending(path: name), atomically: true, encoding: .utf8) }
        let urls = ["a.md", "b.md", "gone.md", "d.md", "e.md"].map { source.appending(path: $0) }

        var reported: [String] = []
        XCTAssertThrowsError(try Drops.copy(urls, into: target) { reported.append($0.lastPathComponent) }) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("Copied 2 of 5 into project — couldn't copy gone.md: "), error.localizedDescription)
        }
        XCTAssertEqual(reported, ["a.md", "b.md"])
    }

    /// "docs" and "Docs" are one folder on a case-insensitive disk: still not into itself.
    func testIntoItselfIgnoresCase() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "drops-\(UUID().uuidString)")
        let inner = tmp.appending(path: "Docs/inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertThrowsError(try Drops.copy([tmp.appending(path: "docs")], into: tmp.appending(path: "DOCS/Inner")))
        XCTAssertEqual(Drops.pasteTarget(selected: FileTree.Entry(path: "Docs", isDirectory: true), pasting: [tmp.appending(path: "docs")],
                                         root: tmp.path), "", "pasted onto itself: next to it")
    }

    func testWhereCommandVPastes() {
        let root = "/Users/me/app", pdf = [URL(filePath: "/Users/me/Downloads/report.pdf")]
        let docs = FileTree.Entry(path: "docs", isDirectory: true)
        XCTAssertEqual(Drops.pasteTarget(selected: docs, pasting: pdf, root: root), "docs", "a folder: into it")
        XCTAssertEqual(Drops.pasteTarget(selected: FileTree.Entry(path: "docs/api/readme.md", isDirectory: false), pasting: pdf, root: root),
                       "docs/api", "a file: into its folder")
        XCTAssertEqual(Drops.pasteTarget(selected: FileTree.Entry(path: "a.md", isDirectory: false), pasting: pdf, root: root), "")
        XCTAssertEqual(Drops.pasteTarget(selected: nil, pasting: pdf, root: root), "", "nothing selected: the root")
        let api = FileTree.Entry(path: "docs/api", isDirectory: true)
        XCTAssertEqual(Drops.pasteTarget(selected: api, pasting: [URL(filePath: "/Users/me/app/docs/api")], root: root), "docs",
                       "a folder pasted onto itself lands next to it, as \"api 2\"")
    }
}

/// Esc in Explorer hands the keyboard back to Claude's terminal, in a real window.
@MainActor
final class ExplorerKeyboardTests: XCTestCase {
    final class Probe {
        var focus: (() -> Void)?
        var giveBack: (() -> Void)?
    }

    private struct Terminal: NSViewRepresentable {
        let view: NSTextView
        func makeNSView(context: Context) -> NSView {
            let container = NSView()
            view.frame = NSRect(x: 0, y: 0, width: 100, height: 40)
            container.addSubview(view)
            return container
        }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    private struct Panel: View {
        let probe: Probe
        let terminal: NSTextView
        @FocusState private var hasKeyboard: Bool

        var body: some View {
            VStack {
                Text("explorer").frame(width: 100, height: 40).focusable().focused($hasKeyboard)
                Terminal(view: terminal).frame(width: 100, height: 40)
            }
            .onAppear {
                probe.focus = { hasKeyboard = true }
                probe.giveBack = { ExplorerSection.giveKeyboardBack(to: terminal, focus: $hasKeyboard) }
            }
        }
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }

    /// Turning the focus off before making the terminal first responder left the keyboard with the window.
    func testEscGivesTheTerminalTheKeyboard() {
        let probe = Probe(), terminal = NSTextView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: Panel(probe: probe, terminal: terminal))
        window.orderFront(nil)
        settle()
        probe.focus?()
        settle()
        XCTAssertFalse(window.firstResponder === terminal, "a click in Explorer takes the keyboard")
        probe.giveBack?()
        settle()
        XCTAssertTrue(window.firstResponder === terminal, "typing goes to Claude again")
    }
}

final class PipelineTitleTests: XCTestCase {
    func testCIShowsTheCommitsSubject() async throws {
        let repo = try makeTempRepo()
        try "x".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        try git(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-qm", "feat: new icon"], in: repo)
        let sha = try XCTUnwrap(GitService.output(["rev-parse", "HEAD"], in: repo.path))

        let titled = await Pipeline.titled(Pipeline(branch: "main", sha: sha, steps: []), in: repo.path)
        XCTAssertEqual(titled?.commitLabel, "“feat: new icon”")
        let unknown = await Pipeline.titled(Pipeline(branch: "main", sha: "5dff4881234", steps: []), in: repo.path)
        XCTAssertEqual(unknown?.commitLabel, "5dff488", "a commit not fetched yet keeps its hash")
    }
}

final class PipelineStoryTests: XCTestCase {
    private func pipeline(_ states: [Pipeline.Step.State]) -> Pipeline {
        let names = ["CI", "Build & Push", "Deploy"]
        return Pipeline(branch: "master", sha: "5dff4881", steps: states.enumerated().map { index, state in
            Pipeline.Step(name: names[index], state: state, trigger: index == 2 ? "deploy.yml" : nil)
        }, title: "fix loans")
    }

    func testOneSentenceSaysWhereItIsAndWhatYouDo() {
        XCTAssertEqual(pipeline([.passed, .running, .manual]).summary.text, "Build & Push is running — step 2 of 3.")
        XCTAssertFalse(pipeline([.passed, .running, .manual]).summary.needsYou)
        let ready = pipeline([.passed, .passed, .manual]).summary
        XCTAssertEqual(ready.text, "Ready: press Run when you want Deploy for “fix loans”.")
        XCTAssertTrue(ready.needsYou)
        XCTAssertEqual(pipeline([.failed, .skipped, .manual]).summary.text, "CI failed — see why, or let Claude fix it.")
        XCTAssertEqual(pipeline([.passed, .passed, .passed]).summary.text, "All steps done for “fix loans”.")
        XCTAssertFalse(pipeline([.passed, .passed, .manual]).isRunning, "waiting for a click isn't running")
        XCTAssertFalse(pipeline([.passed, .manual, .pending]).isRunning, "a stage queued behind a manual gate can wait for days")
        let gate = Pipeline(branch: "main", sha: "abc1234", steps: [Pipeline.Step(name: "Deploy", state: .manual)])
        XCTAssertEqual(gate.summary.text, "Deploy waits for someone's approval on the CI's site.")
    }

    func testPlainWordsForUsualStepNames() {
        XCTAssertEqual(Pipeline.Step.purpose(of: "Deploy"), "puts it live")
        XCTAssertEqual(Pipeline.Step.purpose(of: "Build & Push"), "builds the app")
        XCTAssertEqual(Pipeline.Step.purpose(of: "CI"), "checks the code: tests and linters")
        XCTAssertEqual(Pipeline.Step.purpose(of: "Pipeline"), nil)
    }

    func testDurations() {
        XCTAssertEqual(PipelineView.duration(45), "45s")
        XCTAssertEqual(PipelineView.duration(134), "2m 14s")
        XCTAssertEqual(PipelineView.duration(3780), "1h 3m")
    }
}
