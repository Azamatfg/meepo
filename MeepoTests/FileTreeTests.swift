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
}
