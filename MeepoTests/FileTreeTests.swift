import XCTest
@testable import Meepo

final class FileTreeTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "filetree-\(UUID().uuidString)"
        let fm = FileManager.default
        for dir in ["src", "Assets", ".git", "real"] { try fm.createDirectory(atPath: "\(root!)/\(dir)", withIntermediateDirectories: true) }
        for file in ["b.txt", "A.md", ".DS_Store", ".env", "src/main.swift", "file10", "file2"] {
            fm.createFile(atPath: "\(root!)/\(file)", contents: Data())
        }
        try fm.createSymbolicLink(atPath: "\(root!)/linked", withDestinationPath: "\(root!)/real")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func testFoldersFirstNaturalOrderAndDefaultExcludes() {
        let names = FileTree.list("", in: root).map(\.name)
        // .git/.DS_Store hidden, but dotfiles like .env stay (VS Code shows them); file2 before file10.
        XCTAssertEqual(names, ["Assets", "linked", "real", "src", ".env", "A.md", "b.txt", "file2", "file10"])
    }

    func testSymlinkedFolderIsAFolder() {
        XCTAssertEqual(FileTree.list("", in: root).first { $0.name == "linked" }?.isDirectory, true)
    }

    func testNestedPathsAreRelative() {
        XCTAssertEqual(FileTree.list("src", in: root), [FileTree.Entry(path: "src/main.swift", isDirectory: false)])
    }

    func testFolderMarkedOnlyForChangesInsideIt() {
        let changes = [GitPanel.FileChange(status: "M", path: "Meepo/App.swift")]
        XCTAssertEqual(FileTree.status(of: .init(path: "Meepo", isDirectory: true), changes: changes), "•")
        // A sibling that shares the prefix isn't the same folder.
        XCTAssertNil(FileTree.status(of: .init(path: "Meep", isDirectory: true), changes: changes))
        XCTAssertEqual(FileTree.status(of: .init(path: "Meepo/App.swift", isDirectory: false), changes: changes), "M")
        XCTAssertNil(FileTree.status(of: .init(path: "Meepo/App", isDirectory: false), changes: changes))
    }

    /// The file view reads one byte past 5 MB at most: a big file is turned down without loading it, even behind a link.
    func testFileViewerReadsNoMoreThanItShows() throws {
        let fm = FileManager.default
        func load(_ name: String) -> MonacoDiffView.Content { FileViewer.load("\(root!)/\(name)", as: name) }
        fm.createFile(atPath: "\(root!)/big.log", contents: nil)
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: "\(root!)/big.log"))
        try handle.truncate(atOffset: 1_000_000_000) // sparse: takes no disk
        try handle.close()
        XCTAssertEqual(load("big.log").message, "Over 5 MB — not shown.")
        try fm.createSymbolicLink(atPath: "\(root!)/big-link", withDestinationPath: "\(root!)/big.log")
        XCTAssertEqual(load("big-link").message, "Over 5 MB — not shown.")
        // A file that never ends: only a capped read answers (whole-file contents(atPath:) gives up on it).
        try fm.createSymbolicLink(atPath: "\(root!)/zero", withDestinationPath: "/dev/zero")
        XCTAssertEqual(load("zero").message, "Over 5 MB — not shown.")
        fm.createFile(atPath: "\(root!)/limit.txt", contents: Data(repeating: 0x61, count: 5_000_000))
        XCTAssertEqual(load("limit.txt").modified.utf8.count, 5_000_000, "exactly 5 MB still opens")
        XCTAssertEqual(load("b.txt"), MonacoDiffView.Content(path: "b.txt", isSingle: true), "an empty file opens empty")
        fm.createFile(atPath: "\(root!)/bin", contents: Data([0, 1]))
        XCTAssertEqual(load("bin").message, "Binary file — not shown.")
        XCTAssertEqual(load("src").message, "Can't read this file.", "a folder Claude read")
    }
}
