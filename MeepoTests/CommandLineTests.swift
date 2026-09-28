import GRDB
import XCTest
@testable import Meepo

/// The `meepo` command from the app bundle, with a stand-in `open` that records what it was asked to do.
final class MeepoCommandTests: XCTestCase {
    private func run(_ args: [String]) throws -> (status: Int32, opened: String) {
        let script = try XCTUnwrap(Bundle.main.url(forResource: "meepo", withExtension: nil), "meepo isn't in the app bundle")
        let bin = FileManager.default.temporaryDirectory.appending(path: "fake-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = bin.appending(path: "log")
        try "#!/bin/sh\nprintf '%s ' \"$@\" > '\(log.path)'\n".write(to: bin.appending(path: "open"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: "open").path)
        let process = Process()
        process.executableURL = script
        process.arguments = args
        process.environment = ["PATH": "\(bin.path):/usr/bin:/bin"]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, (try? String(contentsOf: log, encoding: .utf8)) ?? "")
    }

    func testNoArgumentsOpensTheApp() throws {
        XCTAssertEqual(try run([]).opened, "-a Meepo ")
    }

    func testFolderGoesToTheAppAsAnEncodedURL() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Мой проект \(UUID().uuidString.prefix(4))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (status, opened) = try run([folder.path])
        XCTAssertEqual(status, 0)
        let url = try XCTUnwrap(URL(string: opened.trimmingCharacters(in: .whitespaces)))
        XCTAssertEqual(url.scheme, "meepo")
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
        XCTAssertEqual(path, URL(filePath: String(cString: realpath(folder.path, nil))).path)   // spaces and Cyrillic intact
    }

    func testUpdateChecksNowLikeClaudeUpdate() throws {
        XCTAssertEqual(try run(["update"]).opened, "meepo://update ")
    }

    func testMissingFolderFails() throws {
        XCTAssertEqual(try run(["/nowhere/at/all"]).status, 1)
    }
}

@MainActor
final class OpenFromCommandLineTests: XCTestCase {
    private func openURL(_ path: String) -> URL {
        var components = URLComponents(string: "meepo://open")!
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url!
    }

    /// `meepo backend` inside a repo: once confirmed, the repo becomes the project and a session opens;
    /// again → the same session, without asking.
    func testFolderBecomesProjectWithASession() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        let repo = try makeTempRepo()
        try git(["commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        let sub = repo.appending(path: "backend")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        store.openFromCommandLine(openURL(sub.path))
        XCTAssertEqual(store.projects.count, 0)                        // any app can open the URL: ask first
        XCTAssertEqual(store.sessions.count, 0)
        XCTAssertNotNil(store.confirmation)
        store.confirmation?.perform()
        store.confirmation = nil                                        // the card's button does this
        XCTAssertEqual(store.projects.map(\.path), [repo.path])
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.selectedSessionId, store.sessions[0].id)

        store.openFromCommandLine(openURL(sub.path))
        XCTAssertNil(store.confirmation)                                // a known project opens right away
        XCTAssertEqual(store.sessions.count, 1)                         // no duplicate session
    }

    /// A card already open (another folder, an update notice) stays; the new folder isn't dropped without a word.
    func testAFolderWhileAQuestionIsOpenSaysSo() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        store.confirmation = PixelConfirmation(title: "UPDATE FAILED", action: "OK", isDestructive: false) {}
        store.openFromCommandLine(openURL(try makeTempRepo().path))
        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertNotNil(store.bridgeError)
        XCTAssertEqual(store.confirmation?.title, "UPDATE FAILED")
    }

    func testMissingOrRelativeFolderIsIgnored() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        for path in ["/nowhere/at/all", "rel/dir"] {
            store.openFromCommandLine(openURL(path))
            XCTAssertEqual(store.projects.count, 0, path)
            XCTAssertEqual(store.sessions.count, 0, path)
            XCTAssertNil(store.confirmation, path)
        }
    }
}
