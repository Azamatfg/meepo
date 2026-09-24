import XCTest
@testable import Meepo

final class LibraryTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private var backups: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "lib-\(UUID().uuidString)")
        library = root.appending(path: "home/.claude")
        backups = root.appending(path: "backups")
    }

    @discardableResult
    private func write(_ url: URL, _ text: String, age: TimeInterval = 0, executable: Bool = false) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        var attributes: [FileAttributeKey: Any] = [.modificationDate: Date.now.addingTimeInterval(-age)]
        if executable { attributes[.posixPermissions] = 0o755 }
        try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
        return url
    }

    private func project(_ name: String) -> Project {
        Project(id: Int64(abs(name.hashValue % 10_000)), name: name, path: root.appending(path: name).path, remote: nil, color: nil)
    }

    private func claude(_ project: Project, _ path: String) -> URL {
        URL(filePath: project.path).appending(path: ".claude/\(path)")
    }

    /// SPEC module 11 "done when": an edit of ship.md in the library reaches all projects with one button.
    func testShipEditInLibraryReachesOutdatedProjectsOnly() throws {
        let (a, b, c) = (project("a"), project("b"), project("c"))
        try write(claude(a, "commands/ship.md"), "ship v1", age: 3600)
        try write(claude(b, "commands/ship.md"), "ship v1", age: 3600)
        try write(claude(c, "commands/ship.md"), "ship v1 + c's own tweak", age: 10)   // edited after the library
        try write(library.appending(path: "commands/ship.md"), "ship v2", age: 60)

        var item = try XCTUnwrap(Library.scan(library: library, projects: [a, b, c]).first { $0.id == "commands/ship.md" })
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: item.copies.map { ($0.project.name, $0.state) }),
                       ["a": .outdated, "b": .outdated, "c": .newer])

        XCTAssertEqual(try Library.updateOutdated(item, backups: backups), 2)          // the one button
        for p in [a, b] { XCTAssertEqual(try String(contentsOf: claude(p, "commands/ship.md"), encoding: .utf8), "ship v2") }
        XCTAssertEqual(try String(contentsOf: claude(c, "commands/ship.md"), encoding: .utf8), "ship v1 + c's own tweak")
        let saved = try FileManager.default.subpathsOfDirectory(atPath: backups.path).filter { $0.hasSuffix(".md") == false && $0.contains("ship.md-") }
        XCTAssertEqual(saved.count, 2)                                                   // both overwritten copies backed up

        item = try XCTUnwrap(Library.scan(library: library, projects: [a, b, c]).first { $0.id == "commands/ship.md" })
        XCTAssertEqual(item.copies.filter { $0.state == .same }.count, 2)
    }

    func testLiftSharesAProjectEditAndLocalCommands() throws {
        let (a, b) = (project("a"), project("b"))
        try write(library.appending(path: "commands/qa.md"), "qa v1", age: 3600)
        try write(claude(a, "commands/qa.md"), "qa v2 from a", age: 10)
        try write(claude(b, "commands/retro.md"), "retro", age: 10)

        let items = Library.scan(library: library, projects: [a, b])
        let qa = try XCTUnwrap(items.first { $0.id == "commands/qa.md" })
        try Library.lift(qa.copies[0], in: qa, library: library, backups: backups)
        XCTAssertEqual(try String(contentsOf: library.appending(path: "commands/qa.md"), encoding: .utf8), "qa v2 from a")

        let retro = try XCTUnwrap(items.first { $0.id == "commands/retro.md" })
        XCTAssertEqual(retro.copies.map(\.state), [.projectOnly])
        try Library.lift(retro.copies[0], in: retro, library: library, backups: backups)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appending(path: "commands/retro.md").path))
    }

    func testHooksStayExecutableAndWorktreeSymlinksAreIgnored() throws {
        let a = project("a")
        try write(library.appending(path: "hooks/safety.sh"), "#!/bin/bash\necho v2", age: 60, executable: true)
        try write(claude(a, "hooks/safety.sh"), "#!/bin/bash\necho v1", age: 3600, executable: true)
        let worktree = project("a/.claude/worktrees/x")
        try FileManager.default.createDirectory(at: claude(worktree, ""), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: claude(worktree, "hooks"), withDestinationURL: claude(a, "hooks"))

        let items = Library.scan(library: library, projects: [a, worktree])
        let hook = try XCTUnwrap(items.first { $0.id == "hooks/safety.sh" })
        XCTAssertEqual(hook.copies.map(\.project.name), ["a"])                          // the linked copy isn't counted twice
        try Library.updateOutdated(hook, backups: backups)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: claude(a, "hooks/safety.sh").path))
    }

    func testLibraryFolderMayBeARepoRoot() throws {
        let repo = root.appending(path: "practices-repo")
        try FileManager.default.createDirectory(at: repo.appending(path: ".claude/commands"), withIntermediateDirectories: true)
        XCTAssertEqual(Library.resolve(repo).lastPathComponent, ".claude")
        XCTAssertEqual(Library.resolve(library), library)
    }
}

final class DockerParsingTests: XCTestCase {
    func testParsesUsageAndStoppedContainersByComposeProject() {
        let df = """
            {"Active":"3","Reclaimable":"4.2GB (61%)","Size":"6.9GB","TotalCount":"12","Type":"Images"}
            {"Active":"2","Reclaimable":"120MB (40%)","Size":"300MB","TotalCount":"7","Type":"Containers"}
            """
        XCTAssertEqual(Docker.parseUsage(df).map(\.type), ["Images", "Containers"])
        XCTAssertEqual(Docker.parseUsage(df).first?.reclaimable, "4.2GB (61%)")

        let ps = """
            {"Names":"taxi-kolesa-db-1","Labels":"com.docker.compose.project=taxi-kolesa,com.docker.compose.service=db","Status":"Exited (0) 2 days ago","Size":"0B"}
            {"Names":"loose","Labels":"","Status":"Exited (1) 1 hour ago","Size":"12MB"}
            """
        let containers = Docker.parseContainers(ps)
        XCTAssertEqual(containers.map(\.composeProject), ["taxi-kolesa", nil])
        let project = Project(id: 1, name: "taxi-kolesa", path: "/Users/me/Desktop/taxi kolesa project/backend/taxi-kolesa", remote: nil, color: nil)
        XCTAssertEqual(Docker.composeName(of: project), "taxi-kolesa")
    }
}
